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
    
.PARAMETER TargetLIFNames
    Array of target LIF names that will receive the migrated IPs
    
.PARAMETER WhatIf
    Show what would be changed without making modifications
    
.PARAMETER ForceSourceDisable
    Force disable source CIFS server even if sessions are active
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
    
    [Parameter(Mandatory=$true)]
    [string[]]$SourceLIFNames,
    
    [Parameter(Mandatory=$true)]
    [string[]]$TargetLIFNames,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,
    
    [Parameter(Mandatory=$false)]
    [switch]$ForceSourceDisable
)

# Import NetApp PowerShell Toolkit
try {
    Import-Module NetApp.ONTAP -ErrorAction Stop
    Write-Host "[OK] NetApp PowerShell Toolkit loaded successfully" -ForegroundColor Green
} catch {
    Write-Error "Failed to import NetApp.ONTAP module. Please install the NetApp PowerShell Toolkit."
    exit 1
}

# Validate LIF arrays
if ($SourceLIFNames.Count -ne $TargetLIFNames.Count) {
    Write-Error "Source and Target LIF arrays must have the same number of elements"
    exit 1
}

if ($SourceLIFNames.Count -ne 2) {
    Write-Error "This script is designed to migrate exactly 2 LIFs"
    exit 1
}

# Get credentials if not provided
if (-not $SourceCredential) {
    $SourceCredential = Get-Credential -Message "Enter credentials for SOURCE cluster: $SourceCluster"
}

if (-not $TargetCredential) {
    $TargetCredential = Get-Credential -Message "Enter credentials for TARGET cluster: $TargetCluster"
}

# Initialize logging
$LogFile = "CIFS-SVM-Takeover-$(Get-Date -Format 'yyyy-MM-dd-HH-mm-ss').txt"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $LogEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry
}

Write-Log "=== CIFS SVM Takeover and LIF Migration Started ==="
Write-Log "Source: $SourceCluster -> $SourceSVM"
Write-Log "Target: $TargetCluster -> $TargetSVM"
Write-Log "LIF Migration Mappings:"
for ($i = 0; $i -lt $SourceLIFNames.Count; $i++) {
    Write-Log "  $($SourceLIFNames[$i]) -> $($TargetLIFNames[$i])"
}

# Variables to store connection objects
$SourceController = $null
$TargetController = $null

# Variables to store LIF information
$SourceLIFInfo = @()
$TargetLIFInfo = @()

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

    # Step 3: Collect source LIF information
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

    # Step 4: Collect target LIF information
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

    # Step 5: Display migration plan
    Write-Log "=== IP Migration Plan ==="
    for ($i = 0; $i -lt $SourceLIFInfo.Count; $i++) {
        $SourceLIF = $SourceLIFInfo[$i]
        $TargetLIF = $TargetLIFInfo[$i]
        Write-Log "LIF Migration $($i+1):"
        Write-Log "  Source: $($SourceLIF.Name) ($($SourceLIF.IPAddress)/$($SourceLIF.NetmaskLength))"
        Write-Log "  Target: $($TargetLIF.Name) ($($TargetLIF.IPAddress)/$($TargetLIF.NetmaskLength)) -> ($($SourceLIF.IPAddress)/$($SourceLIF.NetmaskLength))"
    }

    # Step 6: Check for active CIFS sessions on source SVM
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

    # Step 7: Disable CIFS server on source SVM
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

    # Step 8: Take source LIFs administratively down
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

    # Step 9: Update target LIF IP addresses
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

    # Step 10: Verify target SVM CIFS server is running
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
            Disconnect-NcController -Controller $SourceController
            Write-Log "[OK] Disconnected from source cluster successfully"
        } catch {
            Write-Log "[NOK] Warning: Could not properly disconnect from source cluster: $($_.Exception.Message)" "WARNING"
        }
    }
    
    if ($TargetController) {
        try {
            Write-Log "Disconnecting from target cluster"
            Disconnect-NcController -Controller $TargetController
            Write-Log "[OK] Disconnected from target cluster successfully"
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
Write-Host "4. Monitor for any client connection issues" -ForegroundColor White
