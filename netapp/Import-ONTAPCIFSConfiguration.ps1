<#
.SYNOPSIS
    ONTAP 9.13 CIFS Share and ACL Import Script
    
.DESCRIPTION
    Imports CIFS shares and ACLs exported by Export-ONTAPCIFSConfiguration.ps1
    and applies them to a target ONTAP cluster and SVM. Works with volumes in SnapMirror relationships.
    
.PARAMETER ImportPath
    Path to the exported configuration directory
    
.PARAMETER TargetCluster
    Target ONTAP cluster management IP or FQDN
    
.PARAMETER TargetSVM
    Target SVM name where configuration will be applied
    
.PARAMETER Credential
    PSCredential object for target ONTAP authentication
    
.PARAMETER WhatIf
    Show what would be imported without making changes
    
.PARAMETER SkipCifsServerCheck
    Skip CIFS server configuration check and setup
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ImportPath,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetCluster,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetSVM,
    
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipCifsServerCheck
)

# Import NetApp PowerShell Toolkit
try {
    Import-Module NetApp.ONTAP -ErrorAction Stop
    Write-Host "[OK] NetApp PowerShell Toolkit loaded successfully" -ForegroundColor Green
} catch {
    Write-Error "Failed to import NetApp.ONTAP module. Please install the NetApp PowerShell Toolkit."
    exit 1
}

# Validate import path
if (!(Test-Path -Path $ImportPath)) {
    Write-Error "Import path not found: $ImportPath"
    exit 1
}

# Get credentials if not provided
if (-not $Credential) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell 7 compatible credential input
        $Username = Read-Host "Enter username for cluster: $TargetCluster"
        $SecurePassword = Read-Host "Enter password" -AsSecureString
        $Credential = New-Object System.Management.Automation.PSCredential($Username, $SecurePassword)
    } else {
        # Windows PowerShell
        $Credential = Get-Credential -Message "Enter credentials for target cluster: $TargetCluster"
    }
}

# Initialize log file
$LogFile = Join-Path $ImportPath "Import-Log-$(Get-Date -Format 'yyyy-MM-dd-HH-mm-ss').txt"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $LogEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry
}

Write-Log "=== ONTAP CIFS Configuration Import Started ==="
Write-Log "Import Path: $ImportPath"
Write-Log "Target Cluster: $TargetCluster"
Write-Log "Target SVM: $TargetSVM"

try {
    # Load export summary
    $SummaryFile = Join-Path $ImportPath "Export-Summary.json"
    if (Test-Path $SummaryFile) {
        $ExportSummary = Get-Content -Path $SummaryFile | ConvertFrom-Json
        Write-Log "[OK] Loaded export summary from: $($ExportSummary.SourceCluster) -> $($ExportSummary.SourceSVM)"
        Write-Log "  Export Date: $($ExportSummary.ExportTimestamp)"
    } else {
        Write-Log "[NOK] Export summary not found, proceeding with file discovery" "WARNING"
    }

    # Connect to target cluster
    Write-Log "Connecting to target cluster: $TargetCluster"
    $TargetController = Connect-NcController -Name $TargetCluster -Credential $Credential
    if (!$TargetController) {
        throw "Failed to connect to target cluster"
    }
    Write-Log "[OK] Connected to target cluster successfully"

    # Load configuration files
    Write-Log "Loading exported configuration files..."
    
    # Load shares
    $SharesFile = Join-Path $ImportPath "CIFS-Shares.json"
    if (Test-Path $SharesFile) {
        $ImportedShares = Get-Content -Path $SharesFile | ConvertFrom-Json
        Write-Log "[OK] Loaded $($ImportedShares.Count) CIFS shares from export"
    } else {
        throw "CIFS shares file not found: $SharesFile"
    }
    
    # Load ACLs
    $ACLsFile = Join-Path $ImportPath "CIFS-ShareACLs.json"
    if (Test-Path $ACLsFile) {
        $ImportedACLs = Get-Content -Path $ACLsFile | ConvertFrom-Json
        Write-Log "[OK] Loaded $($ImportedACLs.Count) share ACL entries from export"
    } else {
        throw "CIFS share ACLs file not found: $ACLsFile"
    }
    
    Write-Log "[OK] Minimal import - shares and ACLs only (no volume or SnapMirror dependencies)"

    # Check CIFS server configuration on target
    if (!$SkipCifsServerCheck) {
        Write-Log "Checking CIFS server configuration on target SVM..."
        try {
            $TargetCifsServer = Get-NcCifsServer -Controller $TargetController -VserverContext $TargetSVM -ErrorAction SilentlyContinue
            
            if (!$TargetCifsServer) {
                Write-Host "`n[NOK] TARGET SVM CIFS CONFIGURATION REQUIRED [NOK]" -ForegroundColor Yellow
                Write-Host "The target SVM must have a CIFS server configured before importing shares." -ForegroundColor Yellow
                Write-Host "Please configure the CIFS server manually on the target SVM and re-run this script." -ForegroundColor Yellow
                
                if (!$WhatIf) {
                    exit 1
                } else {
                    Write-Log "[WHATIF] Would exit due to missing CIFS server configuration"
                }
            } else {
                Write-Log "[OK] Target SVM has CIFS server configured: $($TargetCifsServer.CifsServer)"
            }
        } catch {
            Write-Log "[NOK] Could not check CIFS server status: $($_.Exception.Message)" "WARNING"
        }
    }

    # Import CIFS shares
    Write-Log "Importing CIFS shares to target SVM..."
    $SharesCreated = 0
    foreach ($Share in $ImportedShares) {
        $ShareName = $Share.ShareName
        
        # Skip system shares
        if ($ShareName -in @("admin$", "c$", "ipc$")) {
            Write-Log "Skipping system share: $ShareName"
            continue
        }

        Write-Log "Creating CIFS share: $ShareName at path: $($Share.Path)"
        
        if (!$WhatIf) {
            try {
                # Check if share already exists
                $ExistingShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $ShareName -ErrorAction SilentlyContinue
                if ($ExistingShare) {
                    Write-Log "[NOK] Share '$ShareName' already exists, skipping..." "WARNING"
                    continue
                }

                # Build share parameters
                $ShareParams = @{
                    Controller = $TargetController
                    VserverContext = $TargetSVM
                    Name = $ShareName
                    Path = $Share.Path
                }
                
                if ($Share.Comment) { $ShareParams.Comment = $Share.Comment }
                if ($Share.ShareProperties) { $ShareParams.ShareProperties = $Share.ShareProperties }
                if ($Share.SymlinkProperties) { $ShareParams.SymlinkProperties = $Share.SymlinkProperties }
                if ($Share.FileUmask) { $ShareParams.FileUmask = $Share.FileUmask }
                if ($Share.DirUmask) { $ShareParams.DirUmask = $Share.DirUmask }
                if ($Share.OfflineFilesMode) { $ShareParams.OfflineFilesMode = $Share.OfflineFilesMode }
                if ($Share.AttributeCacheTtl) { $ShareParams.AttributeCacheTtl = $Share.AttributeCacheTtl }
                if ($Share.VscanProfile) { $ShareParams.VscanProfile = $Share.VscanProfile }

                Add-NcCifsShare @ShareParams
                Write-Log "[OK] Successfully created CIFS share: $ShareName"
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
            Write-Log "[WHATIF] Would create CIFS share: $ShareName at path: $($Share.Path)"
        }
    }

    # Import CIFS share ACLs
    Write-Log "Importing CIFS share ACLs..."
    $ACLsCreated = 0
    foreach ($ACL in $ImportedACLs) {
        $ShareName = $ACL.Share
        
        # Skip system shares
        if ($ShareName -in @("admin$", "c$", "ipc$")) {
            continue
        }

        Write-Log "Adding ACL for share '$ShareName': $($ACL.UserOrGroup) = $($ACL.Permission)"
        
        if (!$WhatIf) {
            try {
                Add-NcCifsShareAcl -Controller $TargetController -VserverContext $TargetSVM -Share $ShareName -UserOrGroup $ACL.UserOrGroup -Permission $ACL.Permission -UserGroupType $ACL.UserGroupType
                Write-Log "[OK] Successfully added ACL for share: $ShareName"
                $ACLsCreated++
            } catch {
                Write-Log "[NOK] Failed to add ACL for share $ShareName`: $($_.Exception.Message)" "ERROR"
            }
        } else {
            Write-Log "[WHATIF] Would add ACL: $($ACL.UserOrGroup) = $($ACL.Permission) to share: $ShareName"
        }
    }

    Write-Log "=== CIFS Configuration Import Completed ===" "SUCCESS"
    Write-Log "Shares Created: $SharesCreated"
    Write-Log "ACLs Created: $ACLsCreated"
    
} catch {
    Write-Log "Import failed with error: $($_.Exception.Message)" "ERROR"
    throw
} finally {
    if ($TargetController) {
        try {
            # Disconnect from the specific controller
            Disconnect-NcController $TargetController
            Write-Log "[OK] Disconnected from target cluster"
        } catch {
            Write-Log "[NOK] Warning: Could not properly disconnect from target cluster: $($_.Exception.Message)" "WARNING"
        }
    }
}

# Display summary
Write-Host "`n=== Import Summary ===" -ForegroundColor Cyan
Write-Host "Target: $TargetCluster -> $TargetSVM" -ForegroundColor White
Write-Host "Shares Imported: $SharesCreated" -ForegroundColor Green
Write-Host "ACLs Imported: $ACLsCreated" -ForegroundColor Green
Write-Host "Import Log: $LogFile" -ForegroundColor Yellow