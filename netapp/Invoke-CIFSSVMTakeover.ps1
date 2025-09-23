<#
.SYNOPSIS
    ONTAP 9.13 CIFS SVM Takeover and LIF IP Migration Script
    
.DESCRIPTION
    Disables CIFS services on a source SVM and migrates the IP addresses from 
    source SVM LIFs to specified destination SVM LIFs. This script facilitates
    a seamless takeover of CIFS services from one SVM to another.
    
.PARAMETER SourceCluster
    Source ONTAP cluster management IP or FQDN
    
.PARAMETER TargetCluster  
    Target ONTAP cluster management IP or FQDN
    
.PARAMETER SourceSVM
    Source SVM name containing the CIFS services to disable
    
.PARAMETER TargetSVM
    Target SVM name where LIF IPs will be reconfigured
    
.PARAMETER SourceCredential
    PSCredential object for source ONTAP authentication
    
.PARAMETER TargetCredential
    PSCredential object for target ONTAP authentication
    
.PARAMETER SourceLIFNames
    Array of source LIF names whose IPs will be migrated
    If not specified, script will auto-discover CIFS LIFs on source SVM
    
.PARAMETER TargetLIFNames
    Array of target LIF names that will receive the migrated IPs
    If not specified, script will auto-discover CIFS LIFs on target SVM
    Must have same number of LIFs as source (1:1 mapping)
    
.PARAMETER WhatIf
    Show what would be changed without making modifications
    
.PARAMETER ForceSourceDisable
    Force disable source CIFS server even if sessions are active
    
.PARAMETER SnapMirrorVolumes
    Array of volume names that have SnapMirror relationships to break before cutover
    If not specified, script will auto-discover active SnapMirror volumes on target SVM
    
.PARAMETER SkipSnapMirrorBreak
    Skip SnapMirror break operations (use if already broken manually)
    
.PARAMETER ExportPath
    Path to the CIFS export directory for volume validation (optional)
    If specified, will validate discovered volumes against exported share data
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourceCluster,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetCluster,
    
    [Parameter(Mandatory=$true)]
    [string]$SourceSVM,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetSVM,
    
    [Parameter(Mandatory=$false)]
    [PSCredential]$SourceCredential,
    
    [Parameter(Mandatory=$false)]
    [PSCredential]$TargetCredential,
    
    [Parameter(Mandatory=$false)]
    [string[]]$SourceLIFNames,
    
    [Parameter(Mandatory=$false)]
    [string[]]$TargetLIFNames,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,
    
    [Parameter(Mandatory=$false)]
    [switch]$ForceSourceDisable,
    
    [Parameter(Mandatory=$false)]
    [string[]]$SnapMirrorVolumes,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipSnapMirrorBreak,
    
    [Parameter(Mandatory=$false)]
    [string]$ExportPath
)

# Import NetApp PowerShell Toolkit
try {
    Import-Module NetApp.ONTAP -ErrorAction Stop
    Write-Host "[OK] NetApp PowerShell Toolkit loaded successfully" -ForegroundColor Green
} catch {
    Write-Error "Failed to import NetApp.ONTAP module. Please install the NetApp PowerShell Toolkit."
    exit 1
}

# LIF validation will be done after auto-discovery

# Get credentials if not provided
if (-not $SourceCredential) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell 7 compatible credential input
        $Username = Read-Host "Enter username for SOURCE cluster: $SourceCluster"
        $SecurePassword = Read-Host "Enter password" -AsSecureString
        $SourceCredential = New-Object System.Management.Automation.PSCredential($Username, $SecurePassword)
    } else {
        # Windows PowerShell
        $SourceCredential = Get-Credential -Message "Enter credentials for SOURCE cluster: $SourceCluster"
    }
}

if (-not $TargetCredential) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell 7 compatible credential input
        $Username = Read-Host "Enter username for TARGET cluster: $TargetCluster"
        $SecurePassword = Read-Host "Enter password" -AsSecureString
        $TargetCredential = New-Object System.Management.Automation.PSCredential($Username, $SecurePassword)
    } else {
        # Windows PowerShell
        $TargetCredential = Get-Credential -Message "Enter credentials for TARGET cluster: $TargetCluster"
    }
}

# Initialize logging
$LogFile = "CIFS-SVM-Takeover-$(Get-Date -Format 'yyyy-MM-dd-HH-mm-ss').txt"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $LogEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry
}

# ZAPI function to set advanced CIFS share properties not supported by REST API
function Set-ZapiCifsShareProperties {
    param(
        [Parameter(Mandatory=$true)]
        $Controller,
        
        [Parameter(Mandatory=$true)]
        [string]$VserverContext,
        
        [Parameter(Mandatory=$true)]
        [string]$ShareName,
        
        [Parameter(Mandatory=$true)]
        [string[]]$Properties
    )
    
    try {
        # Build ZAPI XML for cifs-share-properties-modify
        $propertyElements = $Properties | ForEach-Object { "<property>$_</property>" }
        $zapiXml = @"
<cifs-share-properties-modify>
    <vserver>$VserverContext</vserver>
    <share-name>$ShareName</share-name>
    <share-properties>
        $($propertyElements -join '')
    </share-properties>
</cifs-share-properties-modify>
"@
        
        Write-Log "[ZAPI] Setting advanced properties for share '$ShareName': $($Properties -join ', ')"
        
        # Execute ZAPI call
        $result = Invoke-NcSystemApi -Controller $Controller -Request $zapiXml
        
        if ($result) {
            Write-Log "[OK] Successfully set advanced properties for share '$ShareName' via ZAPI"
            return $true
        } else {
            Write-Log "[NOK] ZAPI call returned no result for share '$ShareName'" "WARNING"
            return $false
        }
        
    } catch {
        Write-Log "[NOK] Failed to set advanced properties via ZAPI for share '${ShareName}': $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Function to convert exported share properties to ZAPI format
function Convert-SharePropertiesToZapi {
    param(
        [Parameter(Mandatory=$false)]
        [array]$ShareProperties,
        
        [Parameter(Mandatory=$false)]
        [array]$SymlinkProperties,
        
        [Parameter(Mandatory=$false)]
        [array]$VscanProfile
    )
    
    $zapiProperties = @()
    
    # Map common ShareProperties to ZAPI property names
    if ($ShareProperties) {
        foreach ($prop in $ShareProperties) {
            switch ($prop.ToLower()) {
                "oplocks" { $zapiProperties += "oplocks" }
                "browsable" { $zapiProperties += "browsable" }
                "showsnapshot" { $zapiProperties += "showsnapshot" }
                "changenotify" { $zapiProperties += "changenotify" }
                "homedirectory" { $zapiProperties += "homedirectory" }
                "attributecache" { $zapiProperties += "attributecache" }
                "continuously_available" { $zapiProperties += "continuously_available" }
                "branchcache" { $zapiProperties += "branchcache" }
                "access_based_enumeration" { $zapiProperties += "access_based_enumeration" }
                "shadowcopy" { $zapiProperties += "shadowcopy" }
                default { 
                    Write-Log "[INFO] Unknown ShareProperty '$prop' - attempting to use as-is" "WARNING"
                    $zapiProperties += $prop.ToLower()
                }
            }
        }
    }
    
    # Note: SymlinkProperties and VscanProfile may require separate ZAPI calls
    # For now, log them as requiring manual configuration
    if ($SymlinkProperties) {
        Write-Log "[INFO] SymlinkProperties detected: $($SymlinkProperties -join ', ') - may require separate ZAPI call" "INFO"
    }
    
    if ($VscanProfile) {
        Write-Log "[INFO] VscanProfile detected: $($VscanProfile -join ', ') - may require separate ZAPI call" "INFO"
    }
    
    return $zapiProperties
}

Write-Log "=== CIFS SVM Takeover and LIF Migration Started ==="
Write-Log "Source: $SourceCluster -> $SourceSVM"
Write-Log "Target: $TargetCluster -> $TargetSVM"

if ($SourceLIFNames -and $TargetLIFNames) {
    Write-Log "LIF Migration (specified):"
    for ($i = 0; $i -lt $SourceLIFNames.Count; $i++) {
        Write-Log "  $($SourceLIFNames[$i]) -> $($TargetLIFNames[$i])"
    }
} else {
    Write-Log "LIF Migration: Will auto-discover CIFS LIFs"
}

if ($SnapMirrorVolumes -and $SnapMirrorVolumes.Count -gt 0) {
    Write-Log "SnapMirror Volumes (specified): $($SnapMirrorVolumes -join ', ')"
} elseif (!$SkipSnapMirrorBreak) {
    Write-Log "SnapMirror Volumes: Will auto-discover from target SVM"
}
if ($ExportPath) {
    Write-Log "Export Path: $ExportPath (will validate discovered volumes)"
}

# Variables to store connection objects
$SourceController = $null
$TargetController = $null

# Variables to store LIF information
$SourceLIFInfo = @()
$TargetLIFInfo = @()

# Variables for SnapMirror auto-discovery
$DiscoveredSnapMirrorVolumes = @()
$ExportedShareVolumes = @()

# Variables for LIF auto-discovery
$DiscoveredSourceLIFs = @()
$DiscoveredTargetLIFs = @()

try {
    # Step 1: Connect to source cluster
    Write-Log "Connecting to source cluster: $SourceCluster"
    $SourceController = Connect-NcController -Name $SourceCluster -Credential $SourceCredential
    if (!$SourceController) {
        throw "Failed to connect to source cluster"
    }
    Write-Log "[OK] Connected to source cluster successfully"

    # Step 2: Connect to target cluster
    Write-Log "Connecting to target cluster: $TargetCluster"
    $TargetController = Connect-NcController -Name $TargetCluster -Credential $TargetCredential
    if (!$TargetController) {
        throw "Failed to connect to target cluster"
    }
    Write-Log "[OK] Connected to target cluster successfully"

    # Step 3: Auto-discover CIFS LIFs (if not specified)
    if ((!$SourceLIFNames -or $SourceLIFNames.Count -eq 0) -or (!$TargetLIFNames -or $TargetLIFNames.Count -eq 0)) {
        Write-Log "Auto-discovering CIFS LIFs..."
        
        # Discover source CIFS LIFs
        if (!$SourceLIFNames -or $SourceLIFNames.Count -eq 0) {
            Write-Log "Discovering CIFS LIFs on source SVM: $SourceSVM"
            try {
                $AllSourceLIFs = Get-NcNetInterface -Controller $SourceController -VserverContext $SourceSVM
                Write-Log "[DEBUG] Found $($AllSourceLIFs.Count) total LIFs on source SVM"
                
                # Debug: Show all LIFs for troubleshooting
                foreach ($LIF in $AllSourceLIFs) {
                    Write-Log "[DEBUG] LIF: $($LIF.InterfaceName), Protocols: $($LIF.DataProtocols -join ','), Role: $($LIF.Role), Status: $($LIF.AdministrativeStatus)"
                }
                
                # Filter for CIFS LIFs (require admin up status for source since they should be active)
                $CifsSourceLIFs = $AllSourceLIFs | Where-Object {
                    # Check for CIFS/SMB protocols (handle different ONTAP versions)
                    $HasCifsProtocol = ($_.DataProtocols -contains "cifs") -or 
                                      ($_.DataProtocols -contains "smb") -or 
                                      ($_.DataProtocols -contains "data_cifs") -or
                                      ($_.DataProtocols -join ',' -match 'cifs')
                    
                    # Check for data role (handle different ONTAP versions)
                    $HasDataRole = ($_.Role -eq "data") -or 
                                  ($_.Role -contains "data") -or 
                                  ($_.Role -contains "data_cifs") -or
                                  ($_.Role -match 'data')
                    
                    $HasCifsProtocol -and $_.AdministrativeStatus -eq "up" -and $HasDataRole
                }
                
                if ($CifsSourceLIFs) {
                    $DiscoveredSourceLIFs = $CifsSourceLIFs | Sort-Object InterfaceName
                    $SourceLIFNames = $DiscoveredSourceLIFs | ForEach-Object { $_.InterfaceName }
                    Write-Log "[OK] Discovered $($SourceLIFNames.Count) CIFS LIFs on source SVM:"
                    foreach ($LIF in $DiscoveredSourceLIFs) {
                        Write-Log "  - $($LIF.InterfaceName): $($LIF.Address) (Node: $($LIF.CurrentNode))"
                    }
                } else {
                    Write-Log "[NOK] No active CIFS/SMB data LIFs found on source SVM: $SourceSVM" "ERROR"
                    Write-Log "[INFO] Available LIFs on source SVM (looking for CIFS/data_cifs protocols + data role):" "INFO"
                    $AllSourceLIFs | ForEach-Object {
                        $ProtocolsStr = if ($_.DataProtocols) { $_.DataProtocols -join ',' } else { "none" }
                        $RoleStr = if ($_.Role -is [array]) { $_.Role -join ' ' } else { $_.Role }
                        Write-Log "  - $($_.InterfaceName): Protocols=[$ProtocolsStr] Role=[$RoleStr] Status=$($_.AdministrativeStatus)" "INFO"
                    }
                    throw "No active CIFS/SMB data LIFs found on source SVM: $SourceSVM"
                }
            } catch {
                Write-Log "[NOK] Failed to discover source CIFS LIFs: $($_.Exception.Message)" "ERROR"
                throw
            }
        }
        
        # Discover target CIFS LIFs
        if (!$TargetLIFNames -or $TargetLIFNames.Count -eq 0) {
            Write-Log "Discovering CIFS LIFs on target SVM: $TargetSVM"
            try {
                $AllTargetLIFs = Get-NcNetInterface -Controller $TargetController -VserverContext $TargetSVM
                Write-Log "[DEBUG] Found $($AllTargetLIFs.Count) total LIFs on target SVM"
                
                # Debug: Show all LIFs for troubleshooting
                foreach ($LIF in $AllTargetLIFs) {
                    Write-Log "[DEBUG] LIF: $($LIF.InterfaceName), Protocols: $($LIF.DataProtocols -join ','), Role: $($LIF.Role), Status: $($LIF.AdministrativeStatus)"
                }
                
                # Filter for CIFS LIFs (don't require admin up status for target)
                $CifsTargetLIFs = $AllTargetLIFs | Where-Object {
                    # Check for CIFS/SMB protocols (handle different ONTAP versions)
                    $HasCifsProtocol = ($_.DataProtocols -contains "cifs") -or 
                                      ($_.DataProtocols -contains "smb") -or 
                                      ($_.DataProtocols -contains "data_cifs") -or
                                      ($_.DataProtocols -join ',' -match 'cifs')
                    
                    # Check for data role (handle different ONTAP versions)
                    $HasDataRole = ($_.Role -eq "data") -or 
                                  ($_.Role -contains "data") -or 
                                  ($_.Role -contains "data_cifs") -or
                                  ($_.Role -match 'data')
                    
                    $HasCifsProtocol -and $HasDataRole
                }
                
                if ($CifsTargetLIFs) {
                    $DiscoveredTargetLIFs = $CifsTargetLIFs | Sort-Object InterfaceName
                    $TargetLIFNames = $DiscoveredTargetLIFs | ForEach-Object { $_.InterfaceName }
                    Write-Log "[OK] Discovered $($TargetLIFNames.Count) CIFS LIFs on target SVM:"
                    foreach ($LIF in $DiscoveredTargetLIFs) {
                        Write-Log "  - $($LIF.InterfaceName): $($LIF.Address) (Node: $($LIF.CurrentNode), Status: $($LIF.AdministrativeStatus))"
                    }
                } else {
                    Write-Log "[NOK] No CIFS/SMB data LIFs found on target SVM: $TargetSVM" "ERROR"
                    Write-Log "[INFO] Available LIFs on target SVM (looking for CIFS/data_cifs protocols + data role):" "INFO"
                    $AllTargetLIFs | ForEach-Object {
                        $ProtocolsStr = if ($_.DataProtocols) { $_.DataProtocols -join ',' } else { "none" }
                        $RoleStr = if ($_.Role -is [array]) { $_.Role -join ' ' } else { $_.Role }
                        Write-Log "  - $($_.InterfaceName): Protocols=[$ProtocolsStr] Role=[$RoleStr] Status=$($_.AdministrativeStatus)" "INFO"
                    }
                    throw "No CIFS/SMB data LIFs found on target SVM: $TargetSVM"
                }
            } catch {
                Write-Log "[NOK] Failed to discover target CIFS LIFs: $($_.Exception.Message)" "ERROR"
                throw
            }
        }
    }
    
    # Step 4: Validate LIF mappings
    if ($SourceLIFNames.Count -ne $TargetLIFNames.Count) {
        Write-Log "[NOK] Mismatch in LIF counts: Source has $($SourceLIFNames.Count) LIFs, Target has $($TargetLIFNames.Count) LIFs" "ERROR"
        throw "Source and Target must have the same number of CIFS LIFs for 1:1 migration"
    }
    
    Write-Log "[OK] LIF validation complete - will migrate $($SourceLIFNames.Count) LIF(s)"
    Write-Log "Final LIF migration mappings:"
    for ($i = 0; $i -lt $SourceLIFNames.Count; $i++) {
        Write-Log "  $($SourceLIFNames[$i]) -> $($TargetLIFNames[$i])"
    }

    # Step 5: Auto-discover SnapMirror volumes (if not specified)
    if ((!$SnapMirrorVolumes -or $SnapMirrorVolumes.Count -eq 0) -and !$SkipSnapMirrorBreak) {
        Write-Log "Auto-discovering SnapMirror volumes on target SVM..."
        
        try {
            # Get all SnapMirror relationships where target SVM matches
            Write-Log "[DEBUG] Querying SnapMirror relationships for target SVM: $TargetSVM"
            $AllSnapMirrors = Get-NcSnapmirror -Controller $TargetController
            Write-Log "[DEBUG] Found $($AllSnapMirrors.Count) total SnapMirror relationships"
            
            # Debug: Show all SnapMirror relationships for troubleshooting
            foreach ($SM in $AllSnapMirrors) {
                Write-Log "[DEBUG] SnapMirror: $($SM.SourceLocation) -> $($SM.DestinationLocation) (Status: $($SM.Status), State: $($SM.RelationshipStatus))"
            }
            
            # Filter for target SVM relationships that are not broken-off
            $TargetSnapMirrors = $AllSnapMirrors | Where-Object {
                $_.DestinationLocation -like "$($TargetSVM):*" -and $_.Status -ne "Broken-off"
            }
            
            Write-Log "[DEBUG] Found $($TargetSnapMirrors.Count) SnapMirror relationships for target SVM (non-broken)"
            
            if ($TargetSnapMirrors) {
                foreach ($SM in $TargetSnapMirrors) {
                    # Extract volume name from destination path (format: svm:volume)
                    $VolumeName = ($SM.DestinationLocation -split ':')[1]
                    if ($VolumeName -and $DiscoveredSnapMirrorVolumes -notcontains $VolumeName) {
                        $DiscoveredSnapMirrorVolumes += $VolumeName
                        Write-Log "[OK] Found SnapMirror volume: $VolumeName (Status: $($SM.Status), Source: $($SM.SourceLocation))"
                    }
                }
                
                Write-Log "[OK] Auto-discovered $($DiscoveredSnapMirrorVolumes.Count) SnapMirror volumes"
                $SnapMirrorVolumes = $DiscoveredSnapMirrorVolumes
            } else {
                Write-Log "[WARNING] No active SnapMirror relationships found for target SVM: $TargetSVM" "WARNING"
                Write-Log "[INFO] This could mean:" "INFO"
                Write-Log "  1. No SnapMirror relationships exist for this SVM" "INFO"
                Write-Log "  2. All relationships are already broken-off" "INFO"
                Write-Log "  3. SVM name doesn't match exactly" "INFO"
                
                # Show any broken-off relationships for reference
                $BrokenSnapMirrors = $AllSnapMirrors | Where-Object {
                    $_.DestinationLocation -like "$($TargetSVM):*" -and $_.Status -eq "Broken-off"
                }
                
                if ($BrokenSnapMirrors) {
                    Write-Log "[INFO] Found $($BrokenSnapMirrors.Count) already broken SnapMirror relationships:" "INFO"
                    foreach ($SM in $BrokenSnapMirrors) {
                        $VolumeName = ($SM.DestinationLocation -split ':')[1]
                        Write-Log "  - Volume: $VolumeName (Status: $($SM.Status))" "INFO"
                    }
                }
            }
        } catch {
            Write-Log "[NOK] Failed to discover SnapMirror volumes: $($_.Exception.Message)" "ERROR"
            Write-Log "[DEBUG] Stack trace: $($_.ScriptStackTrace)" "ERROR"
        }
    }
    
    # Step 6: Load and validate export data (if provided)
    if ($ExportPath -and (Test-Path $ExportPath)) {
        Write-Log "Loading export data for volume validation..."
        
        try {
            # Try to load share volumes from export
            $ShareVolumesFile = Join-Path $ExportPath "Share-Volumes.json"
            if (Test-Path $ShareVolumesFile) {
                $ShareVolumesData = Get-Content -Path $ShareVolumesFile | ConvertFrom-Json
                $ExportedShareVolumes = $ShareVolumesData.Volumes
                Write-Log "[OK] Loaded $($ExportedShareVolumes.Count) volumes from export data"
                Write-Log "  Export volumes: $($ExportedShareVolumes -join ', ')"
                
                # Validate discovered SnapMirror volumes against export data
                if ($SnapMirrorVolumes -and $SnapMirrorVolumes.Count -gt 0) {
                    Write-Log "Validating SnapMirror volumes against exported share data..."
                    
                    # Check if all SnapMirror volumes are in the export
                    $MissingInExport = $SnapMirrorVolumes | Where-Object { $_ -notin $ExportedShareVolumes }
                    if ($MissingInExport) {
                        Write-Log "[NOK] SnapMirror volumes not found in export data: $($MissingInExport -join ', ')" "WARNING"
                        Write-Log "  These volumes may not be used by CIFS shares"
                    }
                    
                    # Check if all export volumes have SnapMirror relationships
                    $MissingSnapMirrors = $ExportedShareVolumes | Where-Object { $_ -notin $SnapMirrorVolumes }
                    if ($MissingSnapMirrors) {
                        Write-Log "[NOK] Export volumes without SnapMirror relationships: $($MissingSnapMirrors -join ', ')" "WARNING"
                        Write-Log "  These volumes may need manual verification"
                    }
                    
                    # Show validation summary
                    $MatchingVolumes = $SnapMirrorVolumes | Where-Object { $_ -in $ExportedShareVolumes }
                    Write-Log "[OK] Volume validation complete:"
                    Write-Log "  - Matching volumes (SM + Export): $($MatchingVolumes.Count)"
                    Write-Log "  - SnapMirror only: $($MissingInExport.Count)"
                    Write-Log "  - Export only: $($MissingSnapMirrors.Count)"
                }
            } else {
                Write-Log "[NOK] Share volumes file not found in export: $ShareVolumesFile" "WARNING"
            }
        } catch {
            Write-Log "[NOK] Failed to load export data: $($_.Exception.Message)" "WARNING"
        }
    } elseif ($ExportPath) {
        Write-Log "[NOK] Export path specified but not found: $ExportPath" "WARNING"
    }
    
    # Step 7: Display final SnapMirror volume list
    if ($SnapMirrorVolumes -and $SnapMirrorVolumes.Count -gt 0) {
        Write-Log "Final SnapMirror volumes to process: $($SnapMirrorVolumes -join ', ')"
    } elseif (!$SkipSnapMirrorBreak) {
        Write-Log "[WARNING] No SnapMirror volumes identified for processing" "WARNING"
        Write-Log "[INFO] This means:" "INFO"
        Write-Log "  - Script will skip SnapMirror update/quiesce/break operations" "INFO"
        Write-Log "  - Volume mounting and share creation will still proceed" "INFO"
        Write-Log "  - Use Debug-SnapMirrorDiscovery.ps1 to troubleshoot SnapMirror relationships" "INFO"
    }

    # Step 8: Collect source LIF information
    Write-Log "Collecting source LIF information..."
    foreach ($LifName in $SourceLIFNames) {
        try {
            $SourceLIF = Get-NcNetInterface -Controller $SourceController -VserverContext $SourceSVM -Name $LifName
            if (!$SourceLIF) {
                throw "Source LIF '$LifName' not found on SVM '$SourceSVM'"
            }
            
            $LifInfo = @{
                Name = $SourceLIF.InterfaceName
                IPAddress = $SourceLIF.Address
                Netmask = $SourceLIF.Netmask
                NetmaskLength = $SourceLIF.NetmaskLength
                HomeNode = $SourceLIF.HomeNode
                HomePort = $SourceLIF.HomePort
                CurrentNode = $SourceLIF.CurrentNode
                CurrentPort = $SourceLIF.CurrentPort
                AdminStatus = $SourceLIF.AdministrativeStatus
                DataProtocols = $SourceLIF.DataProtocols
            }
            
            $SourceLIFInfo += $LifInfo
            Write-Log "[OK] Source LIF '$LifName': IP=$($LifInfo.IPAddress), Netmask=$($LifInfo.Netmask)"
            
        } catch {
            Write-Log "[NOK] Failed to get source LIF '$LifName': $($_.Exception.Message)" "ERROR"
            throw
        }
    }

    # Step 9: Collect target LIF information
    Write-Log "Collecting target LIF information..."
    foreach ($LifName in $TargetLIFNames) {
        try {
            $TargetLIF = Get-NcNetInterface -Controller $TargetController -VserverContext $TargetSVM -Name $LifName
            if (!$TargetLIF) {
                throw "Target LIF '$LifName' not found on SVM '$TargetSVM'"
            }
            
            $LifInfo = @{
                Name = $TargetLIF.InterfaceName
                IPAddress = $TargetLIF.Address
                Netmask = $TargetLIF.Netmask
                NetmaskLength = $TargetLIF.NetmaskLength
                HomeNode = $TargetLIF.HomeNode
                HomePort = $TargetLIF.HomePort
                CurrentNode = $TargetLIF.CurrentNode
                CurrentPort = $TargetLIF.CurrentPort
                AdminStatus = $TargetLIF.AdministrativeStatus
                DataProtocols = $TargetLIF.DataProtocols
            }
            
            $TargetLIFInfo += $LifInfo
            Write-Log "[OK] Target LIF '$LifName': Current IP=$($LifInfo.IPAddress), Netmask=$($LifInfo.Netmask)"
            
        } catch {
            Write-Log "[NOK] Failed to get target LIF '$LifName': $($_.Exception.Message)" "ERROR"
            throw
        }
    }

    # Step 10: Display migration plan
    Write-Log "=== IP Migration Plan ==="
    for ($i = 0; $i -lt $SourceLIFInfo.Count; $i++) {
        $SourceLIF = $SourceLIFInfo[$i]
        $TargetLIF = $TargetLIFInfo[$i]
        Write-Log "LIF Migration $($i+1):"
        Write-Log "  Source: $($SourceLIF.Name) ($($SourceLIF.IPAddress)/$($SourceLIF.NetmaskLength))"
        Write-Log "  Target: $($TargetLIF.Name) ($($TargetLIF.IPAddress)/$($TargetLIF.NetmaskLength)) -> ($($SourceLIF.IPAddress)/$($SourceLIF.NetmaskLength))"
    }

    # Step 11: Check for active CIFS sessions on source SVM
    Write-Log "Checking for active CIFS sessions on source SVM..."
    try {
        $ActiveSessions = Get-NcCifsSession -Controller $SourceController -VserverContext $SourceSVM
        if ($ActiveSessions -and $ActiveSessions.Count -gt 0) {
            Write-Log "[NOK] Found $($ActiveSessions.Count) active CIFS sessions on source SVM" "WARNING"
            
            if (!$ForceSourceDisable -and !$WhatIf) {
                Write-Host "`n[NOK] WARNING: Active CIFS Sessions Detected [NOK]" -ForegroundColor Yellow
                Write-Host "The following CIFS sessions are currently active on the source SVM:" -ForegroundColor Yellow
                
                $ActiveSessions | ForEach-Object {
                    Write-Host "  - User: $($_.WindowsUser), IP: $($_.Address), Connected: $($_.ConnectedTime)" -ForegroundColor White
                }
                
                Write-Host "`nDisabling the CIFS server will forcefully disconnect these users." -ForegroundColor Red
                $Proceed = Read-Host "Do you want to proceed with forceful disconnection? (Y/N)"
                
                if ($Proceed -ne "Y" -and $Proceed -ne "y") {
                    Write-Log "Operation cancelled by user due to active CIFS sessions"
                    exit 1
                }
            } elseif ($ForceSourceDisable) {
                Write-Log "Proceeding with force disable despite active sessions"
            }
        } else {
            Write-Log "[OK] No active CIFS sessions found on source SVM"
        }
    } catch {
        Write-Log "[NOK] Could not check CIFS sessions: $($_.Exception.Message)" "WARNING"
    }

    # Step 12: Disable CIFS server on source SVM
    Write-Log "Disabling CIFS server on source SVM..."
    try {
        $SourceCifsServer = Get-NcCifsServer -Controller $SourceController -VserverContext $SourceSVM
        if ($SourceCifsServer) {
            Write-Log "Found CIFS server: $($SourceCifsServer.CifsServer)"
            Write-Log "Domain: $($SourceCifsServer.Domain)"
            Write-Log "Status: $($SourceCifsServer.AdministrativeStatus)"
            
            if ($SourceCifsServer.AdministrativeStatus -eq "up") {
                if (!$WhatIf) {
                    Write-Log "Stopping CIFS server on source SVM..."
                    Stop-NcCifsServer -Controller $SourceController -VserverContext $SourceSVM
                    Write-Log "[OK] CIFS server stopped successfully"
                    
                    # Verify the status
                    Start-Sleep -Seconds 5
                    $UpdatedCifsServer = Get-NcCifsServer -Controller $SourceController -VserverContext $SourceSVM
                    Write-Log "CIFS server status after stop: $($UpdatedCifsServer.AdministrativeStatus)"
                } else {
                    Write-Log "[WHATIF] Would stop CIFS server on source SVM"
                }
            } else {
                Write-Log "CIFS server is already stopped on source SVM"
            }
        } else {
            Write-Log "[NOK] No CIFS server found on source SVM" "WARNING"
        }
    } catch {
        Write-Log "[NOK] Failed to stop CIFS server: $($_.Exception.Message)" "ERROR"
        throw
    }

    # Step 13: Final SnapMirror update (after CIFS is offline)
    if ($SnapMirrorVolumes -and $SnapMirrorVolumes.Count -gt 0 -and !$SkipSnapMirrorBreak) {
        Write-Log "Performing final SnapMirror updates (source CIFS is now offline)..."
        
        foreach ($VolumeName in $SnapMirrorVolumes) {
            $DestinationPath = "$($TargetSVM):$VolumeName"
            Write-Log "Updating SnapMirror for volume: $VolumeName"
            
            if (!$WhatIf) {
                try {
                    # Check current SnapMirror status
                    $SMRelation = Get-NcSnapmirror -Controller $TargetController -Destination $DestinationPath -ErrorAction SilentlyContinue
                    
                    if ($SMRelation) {
                        if ($SMRelation.Status -notin @("Broken-off", "Quiesced")) {
                            Write-Log "Running final SnapMirror update: $DestinationPath"
                            Write-Log "  Current lag time: $($SMRelation.LagTime)"
                            
                            # Perform final update
                            Invoke-NcSnapmirrorUpdate -Controller $TargetController -Destination $DestinationPath
                            
                            # Wait for update to complete
                            Write-Log "Waiting for final SnapMirror update to complete..."
                            do {
                                Start-Sleep -Seconds 15
                                $SMStatus = Get-NcSnapmirror -Controller $TargetController -Destination $DestinationPath
                                Write-Log "  Status: $($SMStatus.Status), Lag: $($SMStatus.LagTime)"
                            } while ($SMStatus.Status -eq "Transferring")
                            
                            Write-Log "[OK] Final SnapMirror update completed for: $DestinationPath"
                            Write-Log "  Final lag time: $($SMStatus.LagTime)"
                            
                        } else {
                            Write-Log "[OK] SnapMirror already quiesced or broken: $DestinationPath (Status: $($SMRelation.Status))"
                        }
                    } else {
                        Write-Log "[NOK] No SnapMirror relationship found for: $DestinationPath" "WARNING"
                    }
                    
                } catch {
                    Write-Log "[NOK] Failed to update SnapMirror for $DestinationPath`: $($_.Exception.Message)" "WARNING"
                    Write-Log "  Continuing with quiesce and break operations..."
                }
            } else {
                Write-Log "[WHATIF] Would perform final SnapMirror update: $DestinationPath"
            }
        }
        
        Write-Log "[OK] Final SnapMirror update operations completed"
    }
    
    # Step 14: Break SnapMirror relationships (if specified)
    if ($SnapMirrorVolumes -and $SnapMirrorVolumes.Count -gt 0 -and !$SkipSnapMirrorBreak) {
        Write-Log "Breaking SnapMirror relationships after final update..."
        
        foreach ($VolumeName in $SnapMirrorVolumes) {
            $DestinationPath = "$($TargetSVM):$VolumeName"
            Write-Log "Processing SnapMirror break for volume: $VolumeName"
            
            if (!$WhatIf) {
                try {
                    # Check current SnapMirror status
                    $SMRelation = Get-NcSnapmirror -Controller $TargetController -Destination $DestinationPath -ErrorAction SilentlyContinue
                    
                    if ($SMRelation) {
                        Write-Log "Found SnapMirror: $($SMRelation.SourceLocation) -> $($SMRelation.DestinationLocation)"
                        Write-Log "Current Status: $($SMRelation.Status)"
                        
                        if ($SMRelation.Status -ne "Broken-off") {
                            # Quiesce the relationship first (if not already done)
                            if ($SMRelation.Status -ne "Quiesced") {
                                Write-Log "Quiescing SnapMirror: $DestinationPath"
                                Invoke-NcSnapmirrorQuiesce -Controller $TargetController -Destination $DestinationPath
                                
                                # Wait for quiesce to complete
                                Write-Log "Waiting for quiesce to complete..."
                                do {
                                    Start-Sleep -Seconds 10
                                    $SMStatus = Get-NcSnapmirror -Controller $TargetController -Destination $DestinationPath
                                    Write-Log "  Status: $($SMStatus.Status)"
                                } while ($SMStatus.Status -eq "Quiescing")
                            } else {
                                Write-Log "SnapMirror already quiesced: $DestinationPath"
                            }
                            
                            # Break the relationship
                            Write-Log "Breaking SnapMirror: $DestinationPath"
                            Invoke-NcSnapmirrorBreak -Controller $TargetController -Destination $DestinationPath
                            
                            # Verify break was successful and check volume mounting
                            Start-Sleep -Seconds 5
                            $SMFinal = Get-NcSnapmirror -Controller $TargetController -Destination $DestinationPath
                            Write-Log "[OK] SnapMirror broken successfully: $($SMFinal.Status)"
                            
                            # Verify if volume was automatically mounted
                            $Volume = Get-NcVol -Controller $TargetController -VserverContext $TargetSVM -Name $VolumeName -ErrorAction SilentlyContinue
                            if ($Volume -and $Volume.JunctionPath -and $Volume.JunctionPath -ne "") {
                                Write-Log "[OK] Volume '$VolumeName' automatically mounted at: $($Volume.JunctionPath)"
                            } else {
                                Write-Log "[INFO] Volume '$VolumeName' not automatically mounted - will mount manually during share creation"
                            }
                            
                        } else {
                            Write-Log "[OK] SnapMirror already broken: $DestinationPath"
                        }
                    } else {
                        Write-Log "[NOK] No SnapMirror relationship found for: $DestinationPath" "WARNING"
                    }
                    
                } catch {
                    Write-Log "[NOK] Failed to break SnapMirror for $DestinationPath`: $($_.Exception.Message)" "ERROR"
                    if (!$ForceSourceDisable) {
                        throw "SnapMirror break failed. Use -ForceSourceDisable to continue anyway."
                    }
                }
            } else {
                Write-Log "[WHATIF] Would quiesce and break SnapMirror: $DestinationPath"
            }
        }
        
        Write-Log "[OK] SnapMirror break operations completed"
    } elseif ($SkipSnapMirrorBreak) {
        Write-Log "Skipping SnapMirror operations as requested"
    } else {
        Write-Log "No SnapMirror volumes specified - continuing without SnapMirror operations"
    }
    
    # Step 15: Mount volumes and create exported CIFS shares and ACLs (after SnapMirror break)
    if ($ExportPath -and (Test-Path $ExportPath)) {
        Write-Log "Processing exported CIFS shares and volume mounting..."
        
        # Load exported shares and ACLs directly
        $SharesFile = Join-Path $ExportPath "CIFS-Shares.json"
        $ACLsFile = Join-Path $ExportPath "CIFS-ShareACLs.json"
        
        if ((Test-Path $SharesFile) -and (Test-Path $ACLsFile)) {
            try {
                # Load exported shares and ACLs
                $ExportedShares = Get-Content -Path $SharesFile | ConvertFrom-Json
                $ExportedACLs = Get-Content -Path $ACLsFile | ConvertFrom-Json
                
                # Filter out system shares
                $SharesForProcessing = $ExportedShares | Where-Object { $_.ShareName -notin @("admin$", "c$", "ipc$") }
                $ACLsForProcessing = $ExportedACLs | Where-Object { $_.Share -notin @("admin$", "c$", "ipc$") }
                
                Write-Log "[OK] Found $($SharesForProcessing.Count) exported shares and $($ACLsForProcessing.Count) exported ACLs"
                
                # Derive required junction paths and mount volumes
                $RequiredJunctions = @{}
                foreach ($Share in $SharesForProcessing) {
                    # Only process static shares for volume mounting
                    if ($Share.Path -and $Share.Path.StartsWith('/') -and !($Share.Path -match '%[wdWD]')) {
                        $PathParts = $Share.Path.Trim('/').Split('/')
                        if ($PathParts.Length -gt 0 -and $PathParts[0] -ne "") {
                            $VolumeName = $PathParts[0]
                            $JunctionPath = "/" + ($PathParts -join '/')
                            
                            # Only store the junction for the root level (volume mount point)
                            $VolumeJunction = "/" + $VolumeName
                            if (!$RequiredJunctions.ContainsKey($VolumeName)) {
                                $RequiredJunctions[$VolumeName] = $VolumeJunction
                            }
                        }
                    }
                }
                
                Write-Log "[OK] Identified $($RequiredJunctions.Count) volumes that need mounting"
                
                # Mount volumes if they're not already mounted
                foreach ($VolumeName in $RequiredJunctions.Keys) {
                    $JunctionPath = $RequiredJunctions[$VolumeName]
                    
                    if (!$WhatIf) {
                        try {
                            # Check if volume is already mounted
                            $Volume = Get-NcVol -Controller $TargetController -VserverContext $TargetSVM -Name $VolumeName -ErrorAction SilentlyContinue
                            if ($Volume) {
                                if ($Volume.JunctionPath -and $Volume.JunctionPath -ne "") {
                                    Write-Log "[OK] Volume '$VolumeName' already mounted at: $($Volume.JunctionPath)"
                                } else {
                                    Write-Log "Mounting volume '$VolumeName' at junction: $JunctionPath"
                                    Set-NcVol -Controller $TargetController -VserverContext $TargetSVM -Name $VolumeName -JunctionPath $JunctionPath
                                    Write-Log "[OK] Successfully mounted volume '$VolumeName' at: $JunctionPath"
                                }
                            } else {
                                Write-Log "[NOK] Volume '$VolumeName' not found on target SVM" "ERROR"
                            }
                        } catch {
                            Write-Log "[NOK] Failed to mount volume '$VolumeName': $($_.Exception.Message)" "ERROR"
                        }
                    } else {
                        Write-Log "[WHATIF] Would mount volume '$VolumeName' at junction: $JunctionPath"
                    }
                }
                
                # Create CIFS shares from export
                Write-Log "Creating exported CIFS shares..."
                $SharesCreated = 0
                
                foreach ($Share in $SharesForProcessing) {
                    $ShareName = $Share.ShareName
                    $ShareType = if ($Share.Path -match '%[wdWD]') { "dynamic" } else { "static" }
                    
                    Write-Log "Creating exported CIFS $ShareType share: $ShareName at path: $($Share.Path)"
                    
                    if (!$WhatIf) {
                        try {
                            # Check if share already exists
                            $ExistingShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $ShareName -ErrorAction SilentlyContinue
                            if ($ExistingShare) {
                                Write-Log "[WARNING] Share '$ShareName' already exists, skipping..." "WARNING"
                                continue
                            }

                            # Build share parameters (REST-compatible only)
                            $ShareParams = @{
                                Controller = $TargetController
                                VserverContext = $TargetSVM
                                Name = $ShareName
                                Path = $Share.Path
                            }
                            
                            # Add basic parameters that are REST API compatible
                            if ($Share.Comment) { $ShareParams.Comment = $Share.Comment }
                            if ($Share.FileUmask) { $ShareParams.FileUmask = $Share.FileUmask }
                            if ($Share.DirUmask) { $ShareParams.DirUmask = $Share.DirUmask }
                            if ($Share.OfflineFilesMode) { $ShareParams.OfflineFilesMode = $Share.OfflineFilesMode }
                            if ($Share.AttributeCacheTtl) { $ShareParams.AttributeCacheTtl = $Share.AttributeCacheTtl }
                            
                            # Create the basic share first
                            Add-NcCifsShare @ShareParams
                            Write-Log "[OK] Successfully created CIFS $ShareType share: $ShareName"
                            
                            # Configure advanced properties via ZAPI if needed
                            $AdvancedPropsSet = $false
                            if ($Share.ShareProperties -or $Share.SymlinkProperties -or $Share.VscanProfile) {
                                Write-Log "[INFO] Configuring advanced properties for share: $ShareName"
                                
                                try {
                                    # Convert exported properties to ZAPI format
                                    $ZapiProperties = Convert-SharePropertiesToZapi -ShareProperties $Share.ShareProperties -SymlinkProperties $Share.SymlinkProperties -VscanProfile $Share.VscanProfile
                                    
                                    if ($ZapiProperties.Count -gt 0) {
                                        # Set advanced properties via ZAPI
                                        $AdvancedPropsSet = Set-ZapiCifsShareProperties -Controller $TargetController -VserverContext $TargetSVM -ShareName $ShareName -Properties $ZapiProperties
                                        
                                        if ($AdvancedPropsSet) {
                                            Write-Log "[OK] Advanced properties configured via ZAPI for share: $ShareName"
                                        } else {
                                            Write-Log "[NOK] Failed to configure some advanced properties for share: $ShareName" "WARNING"
                                        }
                                    } else {
                                        Write-Log "[INFO] No mappable advanced properties found for share: $ShareName" "INFO"
                                    }
                                    
                                } catch {
                                    Write-Log "[NOK] Error configuring advanced properties for share ${ShareName}: $($_.Exception.Message)" "ERROR"
                                }
                            }
                            
                            $SharesCreated++
                            
                            # Remove default Everyone permission
                            try {
                                Remove-NcCifsShareAcl -Controller $TargetController -VserverContext $TargetSVM -Share $ShareName -UserOrGroup "Everyone" -ErrorAction SilentlyContinue
                                Write-Log "[OK] Removed default Everyone permission for: $ShareName"
                            } catch {
                                Write-Log "[NOK] Could not remove Everyone permission for $ShareName" "WARNING"
                            }
                            
                        } catch {
                            Write-Log "[NOK] Failed to create CIFS share $ShareName`: $($_.Exception.Message)" "ERROR"
                        }
                    } else {
                        Write-Log "[WHATIF] Would create deferred CIFS $ShareType share: $ShareName at path: $($Share.Path)"
                    }
                }
                
                # Apply exported ACLs
                Write-Log "Applying exported CIFS share ACLs..."
                $ACLsCreated = 0
                
                foreach ($ACL in $ACLsForProcessing) {
                    $ShareName = $ACL.Share
                    Write-Log "Adding exported ACL for share '$ShareName': $($ACL.UserOrGroup) = $($ACL.Permission)"
                    
                    if (!$WhatIf) {
                        try {
                            Add-NcCifsShareAcl -Controller $TargetController -VserverContext $TargetSVM -Share $ShareName -UserOrGroup $ACL.UserOrGroup -Permission $ACL.Permission -UserGroupType $ACL.UserGroupType
                            Write-Log "[OK] Successfully added exported ACL for share: $ShareName"
                            $ACLsCreated++
                        } catch {
                            Write-Log "[NOK] Failed to add exported ACL for share $ShareName`: $($_.Exception.Message)" "ERROR"
                        }
                    } else {
                        Write-Log "[WHATIF] Would add exported ACL: $($ACL.UserOrGroup) = $($ACL.Permission) to share: $ShareName"
                    }
                }
                
                Write-Log "[OK] Exported CIFS configuration applied - Shares: $SharesCreated, ACLs: $ACLsCreated" "SUCCESS"
                Write-Log "[INFO] Advanced share properties (ShareProperties, SymlinkProperties, VscanProfile) configured via ZAPI where applicable" "INFO"
                
            } catch {
                Write-Log "[NOK] Failed to process exported CIFS configuration: $($_.Exception.Message)" "ERROR"
            }
            
        } else {
            Write-Log "[INFO] No exported shares/ACLs found - check export files in path: $ExportPath" "WARNING"
        }
        
    } else {
        Write-Log "[INFO] No export path specified - skipping CIFS share processing"
    }

    # Step 16: Take source LIFs administratively down
    Write-Log "Taking source LIFs administratively down..."
    for ($i = 0; $i -lt $SourceLIFInfo.Count; $i++) {
        $SourceLIF = $SourceLIFInfo[$i]
        
        if ($SourceLIF.AdminStatus -eq "up") {
            if (!$WhatIf) {
                try {
                    Write-Log "Setting source LIF '$($SourceLIF.Name)' administratively down..."
                    Set-NcNetInterface -Controller $SourceController -VserverContext $SourceSVM -Name $SourceLIF.Name -AdministrativeStatus down
                    Write-Log "[OK] Source LIF '$($SourceLIF.Name)' set to administratively down"
                } catch {
                    Write-Log "[NOK] Failed to set source LIF '$($SourceLIF.Name)' down: $($_.Exception.Message)" "ERROR"
                }
            } else {
                Write-Log "[WHATIF] Would set source LIF '$($SourceLIF.Name)' administratively down"
            }
        } else {
            Write-Log "Source LIF '$($SourceLIF.Name)' is already administratively down"
        }
    }

    # Step 17: Update target LIF IP addresses
    Write-Log "Updating target LIF IP addresses..."
    for ($i = 0; $i -lt $SourceLIFInfo.Count; $i++) {
        $SourceLIF = $SourceLIFInfo[$i]
        $TargetLIF = $TargetLIFInfo[$i]
        
        Write-Log "Migrating IP from '$($SourceLIF.Name)' to '$($TargetLIF.Name)'"
        Write-Log "  Changing IP: $($TargetLIF.IPAddress) -> $($SourceLIF.IPAddress)"
        Write-Log "  Netmask: $($SourceLIF.Netmask)"
        
        if (!$WhatIf) {
            try {
                # First, take target LIF down
                Write-Log "Setting target LIF '$($TargetLIF.Name)' administratively down..."
                Set-NcNetInterface -Controller $TargetController -VserverContext $TargetSVM -Name $TargetLIF.Name -AdministrativeStatus down
                
                # Wait a moment for the change to take effect
                Start-Sleep -Seconds 3
                
                # Update the IP address and netmask
                Write-Log "Updating IP address and netmask for target LIF '$($TargetLIF.Name)'..."
                Set-NcNetInterface -Controller $TargetController -VserverContext $TargetSVM -Name $TargetLIF.Name -Address $SourceLIF.IPAddress -Netmask $SourceLIF.Netmask
                
                # Wait a moment for the IP change to take effect
                Start-Sleep -Seconds 3
                
                # Bring target LIF back up
                Write-Log "Bringing target LIF '$($TargetLIF.Name)' administratively up..."
                Set-NcNetInterface -Controller $TargetController -VserverContext $TargetSVM -Name $TargetLIF.Name -AdministrativeStatus up
                
                Write-Log "[OK] Successfully migrated IP to target LIF '$($TargetLIF.Name)'"
                
                # Verify the change
                Start-Sleep -Seconds 5
                $UpdatedLIF = Get-NcNetInterface -Controller $TargetController -VserverContext $TargetSVM -Name $TargetLIF.Name
                Write-Log "Verification: LIF '$($TargetLIF.Name)' now has IP: $($UpdatedLIF.Address), Status: $($UpdatedLIF.AdministrativeStatus)"
                
            } catch {
                Write-Log "[NOK] Failed to update target LIF '$($TargetLIF.Name)': $($_.Exception.Message)" "ERROR"
                
                # Attempt to bring the LIF back up even if IP change failed
                try {
                    Write-Log "Attempting to bring target LIF '$($TargetLIF.Name)' back up after error..."
                    Set-NcNetInterface -Controller $TargetController -VserverContext $TargetSVM -Name $TargetLIF.Name -AdministrativeStatus up
                } catch {
                    Write-Log "[NOK] Failed to bring target LIF '$($TargetLIF.Name)' back up: $($_.Exception.Message)" "ERROR"
                }
            }
        } else {
            Write-Log "[WHATIF] Would update target LIF '$($TargetLIF.Name)' with IP: $($SourceLIF.IPAddress), Netmask: $($SourceLIF.Netmask)"
        }
    }

    # Step 18: Verify target SVM CIFS server is running
    Write-Log "Verifying target SVM CIFS server status..."
    try {
        $TargetCifsServer = Get-NcCifsServer -Controller $TargetController -VserverContext $TargetSVM
        if ($TargetCifsServer) {
            Write-Log "[OK] Target CIFS server: $($TargetCifsServer.CifsServer)"
            Write-Log "  Status: $($TargetCifsServer.AdministrativeStatus)"
            Write-Log "  Domain: $($TargetCifsServer.Domain)"
            
            if ($TargetCifsServer.AdministrativeStatus -ne "up") {
                Write-Log "[NOK] Target CIFS server is not running - you may need to start it manually" "WARNING"
            }
        } else {
            Write-Log "[NOK] No CIFS server found on target SVM" "WARNING"
        }
    } catch {
        Write-Log "[NOK] Could not check target CIFS server status: $($_.Exception.Message)" "WARNING"
    }

    Write-Log "=== CIFS SVM Takeover Completed Successfully ==="
    
} catch {
    Write-Log "CIFS SVM Takeover failed with error: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    throw
} finally {
    # Cleanup connections
    if ($SourceController) {
        try {
            Write-Log "Disconnecting from source cluster"
            # Check if disconnect cmdlet is available
            if (Get-Command "Disconnect-NcController" -ErrorAction SilentlyContinue) {
                Disconnect-NcController $SourceController
                Write-Log "[OK] Disconnected from source cluster successfully"
            } else {
                # No explicit disconnect cmdlet available - connection will close when session ends
                Write-Log "[OK] Source cluster connection will close automatically when session ends"
            }
        } catch {
            Write-Log "[NOK] Warning: Could not properly disconnect from source cluster: $($_.Exception.Message)" "WARNING"
        }
    }
    
    if ($TargetController) {
        try {
            Write-Log "Disconnecting from target cluster"
            # Check if disconnect cmdlet is available
            if (Get-Command "Disconnect-NcController" -ErrorAction SilentlyContinue) {
                Disconnect-NcController $TargetController
                Write-Log "[OK] Disconnected from target cluster successfully"
            } else {
                # No explicit disconnect cmdlet available - connection will close when session ends
                Write-Log "[OK] Target cluster connection will close automatically when session ends"
            }
        } catch {
            Write-Log "[NOK] Warning: Could not properly disconnect from target cluster: $($_.Exception.Message)" "WARNING"
        }
    }
}

# Display summary
Write-Host "`n=== CIFS SVM Takeover Summary ===" -ForegroundColor Cyan
Write-Host "Source: $SourceCluster -> $SourceSVM (CIFS Disabled)" -ForegroundColor Red
Write-Host "Target: $TargetCluster -> $TargetSVM (IPs Updated)" -ForegroundColor Green
Write-Host "LIF Migrations Completed: $($SourceLIFNames.Count)" -ForegroundColor Green
Write-Host "Log File: $LogFile" -ForegroundColor Yellow

Write-Host "`nIP Migration Summary:" -ForegroundColor Cyan
for ($i = 0; $i -lt $SourceLIFNames.Count; $i++) {
    if ($SourceLIFInfo.Count -gt $i) {
        Write-Host "  $($TargetLIFNames[$i]) -> $($SourceLIFInfo[$i].IPAddress)" -ForegroundColor Green
    }
}

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Test connectivity to the new IP addresses" -ForegroundColor White
Write-Host "2. Update DNS records if necessary" -ForegroundColor White
Write-Host "3. Verify CIFS shares are accessible via target SVM" -ForegroundColor White
Write-Host "4. Verify advanced share properties were applied correctly (OpLocks, ChangeNotify, ABE, etc.)" -ForegroundColor White
Write-Host "5. Monitor for any client connection issues" -ForegroundColor White
