<#
.SYNOPSIS
    ONTAP 9.13 CIFS Share and ACL Export Script
    
.DESCRIPTION
    Exports only CIFS shares and ACLs from a source ONTAP cluster for migration to a target cluster.
    This minimal export can be run while volumes are still in SnapMirror relationships.
    
.PARAMETER SourceCluster
    Source ONTAP cluster management IP or FQDN
    
.PARAMETER SourceSVM
    Source SVM name containing the CIFS shares
    
.PARAMETER Credential
    PSCredential object for source ONTAP authentication
    
.PARAMETER ExportPath
    Path to store exported configuration files
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourceCluster,
    
    [Parameter(Mandatory=$true)]
    [string]$SourceSVM,
    
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,
    
    [Parameter(Mandatory=$false)]
    [string]$ExportPath = "C:\ONTAP_Export"
)

# Import NetApp PowerShell Toolkit
try {
    Import-Module NetApp.ONTAP -ErrorAction Stop
    Write-Host "[OK] NetApp PowerShell Toolkit loaded successfully" -ForegroundColor Green
} catch {
    Write-Error "Failed to import NetApp.ONTAP module. Please install the NetApp PowerShell Toolkit."
    exit 1
}

# Create export directory with timestamp
$ExportTimestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$ExportDirectory = Join-Path $ExportPath "$SourceSVM`_Export_$ExportTimestamp"
New-Item -ItemType Directory -Path $ExportDirectory -Force | Out-Null

# Get credentials if not provided
if (-not $Credential) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell 7 compatible credential input
        $Username = Read-Host "Enter username for cluster: $SourceCluster"
        $SecurePassword = Read-Host "Enter password" -AsSecureString
        $Credential = New-Object System.Management.Automation.PSCredential($Username, $SecurePassword)
    } else {
        # Windows PowerShell
        $Credential = Get-Credential -Message "Enter credentials for source cluster: $SourceCluster"
    }
}

# Initialize log file
$LogFile = Join-Path $ExportDirectory "Export-Log.txt"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $LogEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry
}

Write-Log "=== ONTAP CIFS Configuration Export Started ==="
Write-Log "Source Cluster: $SourceCluster"
Write-Log "Source SVM: $SourceSVM"
Write-Log "Export Directory: $ExportDirectory"

$ExportSummary = @{
    ExportTimestamp = $ExportTimestamp
    SourceCluster = $SourceCluster
    SourceSVM = $SourceSVM
    ExportDirectory = $ExportDirectory
    Shares = @()
    ShareACLs = @()
    ShareVolumes = @()
    ExportedFiles = @()
}

try {
    # Connect to source cluster
    Write-Log "Connecting to source cluster: $SourceCluster"
    $SourceController = Connect-NcController -Name $SourceCluster -Credential $Credential
    if (!$SourceController) {
        throw "Failed to connect to source cluster"
    }
    Write-Log "[OK] Connected to source cluster successfully"

    # Step 1: Export CIFS Shares
    Write-Log "Collecting CIFS shares..."
    $AllCifsShares = Get-NcCifsShare -Controller $SourceController -VserverContext $SourceSVM
    
    # Filter out only system administrative shares (not user-created hidden shares)
    $SystemShares = @("admin$", "c$", "ipc$")
    $CifsShares = $AllCifsShares | Where-Object {
        $_.ShareName -notin $SystemShares
    }
    
    $SystemSharesCount = $AllCifsShares.Count - $CifsShares.Count
    Write-Log "[OK] Found $($AllCifsShares.Count) total CIFS shares, filtered out $SystemSharesCount system administrative shares"
    if ($SystemSharesCount -gt 0) {
        $FilteredShares = $AllCifsShares | Where-Object { $_.ShareName -in $SystemShares } | ForEach-Object { $_.ShareName }
        Write-Log "  Filtered system shares: $($FilteredShares -join ', ')"
    }
    
    $SharesFile = Join-Path $ExportDirectory "CIFS-Shares.json"
    $SharesFileXML = Join-Path $ExportDirectory "CIFS-Shares.xml"
    
    # Export in both JSON and XML formats for compatibility
    $CifsShares | ConvertTo-Json -Depth 10 | Out-File -FilePath $SharesFile -Encoding UTF8
    $CifsShares | Export-Clixml -Path $SharesFileXML
    
    $ExportSummary.Shares = $CifsShares
    $ExportSummary.ExportedFiles += @($SharesFile, $SharesFileXML)
    Write-Log "[OK] Exported $($CifsShares.Count) shares (including user-created hidden shares) to: $SharesFile"

    # Export detailed share information to CSV for review (with proper array handling)
    $SharesCSV = Join-Path $ExportDirectory "CIFS-Shares-Details.csv"
    $CifsShares | Select-Object ShareName, Path, Comment, 
        @{Name='ShareProperties';Expression={if($_.ShareProperties -and $_.ShareProperties.Count -gt 0) {$_.ShareProperties -join '; '} else {''}}}, 
        @{Name='SymlinkProperties';Expression={if($_.SymlinkProperties -and $_.SymlinkProperties.Count -gt 0) {$_.SymlinkProperties -join '; '} else {''}}}, 
        @{Name='VscanProfile';Expression={if($_.VscanProfile -and $_.VscanProfile.Count -gt 0) {$_.VscanProfile -join '; '} else {''}}}, 
        @{Name='IsDynamic';Expression={if($_.Path -match '%[wdWD]') {'Yes'} else {'No'}}} | 
        Export-Csv -Path $SharesCSV -NoTypeInformation
    $ExportSummary.ExportedFiles += $SharesCSV
    Write-Log "[OK] CIFS shares details exported to: $SharesCSV (arrays converted to semicolon-separated values)"

    # Step 2: Export CIFS Share ACLs
    Write-Log "Collecting CIFS share ACLs..."
    $AllShareACLs = Get-NcCifsShareAcl -Controller $SourceController -VserverContext $SourceSVM
    
    # Filter ACLs to only include those for non-system shares
    $UserShareNames = $CifsShares | ForEach-Object { $_.ShareName }
    $ShareACLs = $AllShareACLs | Where-Object { $_.Share -in $UserShareNames }
    
    $FilteredACLsCount = $AllShareACLs.Count - $ShareACLs.Count
    Write-Log "[OK] Found $($AllShareACLs.Count) total share ACL entries, filtered out $FilteredACLsCount ACLs for system administrative shares"
    
    $ACLsFile = Join-Path $ExportDirectory "CIFS-ShareACLs.json"
    $ACLsFileXML = Join-Path $ExportDirectory "CIFS-ShareACLs.xml"
    
    $ShareACLs | ConvertTo-Json -Depth 10 | Out-File -FilePath $ACLsFile -Encoding UTF8
    $ShareACLs | Export-Clixml -Path $ACLsFileXML
    
    $ExportSummary.ShareACLs = $ShareACLs
    $ExportSummary.ExportedFiles += @($ACLsFile, $ACLsFileXML)
    Write-Log "[OK] Exported $($ShareACLs.Count) share ACL entries for non-system shares to: $ACLsFile"

    # Export ACLs to CSV for review
    $ACLsCSV = Join-Path $ExportDirectory "CIFS-ShareACLs-Details.csv"
    $ShareACLs | Select-Object Share, UserOrGroup, UserGroupType, Permission | Export-Csv -Path $ACLsCSV -NoTypeInformation
    $ExportSummary.ExportedFiles += $ACLsCSV

    # Step 3: Extract and export volume names from share paths
    Write-Log "Extracting volume names from CIFS share paths..."
    $ShareVolumes = @()
    
    $DynamicShares = @()
    $StaticShares = @()
    
    foreach ($Share in $CifsShares) {
        # Check if this is a dynamic share (contains variables like %w, %d)
        $IsDynamic = $Share.Path -match '%[wdWD]'
        
        if ($IsDynamic) {
            $DynamicShares += $Share
            Write-Log "[OK] Found dynamic share: $($Share.ShareName) with path: $($Share.Path)"
        } else {
            $StaticShares += $Share
            
            # Extract volume name from static paths only (format: /volume_name/...)
            if ($Share.Path -and $Share.Path.StartsWith('/')) {
                $PathParts = $Share.Path.Trim('/').Split('/')
                if ($PathParts.Length -gt 0 -and $PathParts[0] -ne "") {
                    $VolumeName = $PathParts[0]
                    if ($ShareVolumes -notcontains $VolumeName) {
                        $ShareVolumes += $VolumeName
                        Write-Log "[OK] Found volume: $VolumeName (from share: $($Share.ShareName))"
                    }
                }
            }
        }
    }
    
    if ($DynamicShares.Count -gt 0) {
        Write-Log "[OK] Found $($DynamicShares.Count) dynamic shares with variable substitution"
        Write-Log "  Dynamic shares: $($DynamicShares.ShareName -join ', ')"
    }
    
    # Export volume list
    if ($ShareVolumes.Count -gt 0) {
        $VolumesFile = Join-Path $ExportDirectory "Share-Volumes.json"
        $VolumeData = @{
            SourceSVM = $SourceSVM
            SourceCluster = $SourceCluster
            Volumes = $ShareVolumes | Sort-Object
            ExtractedFrom = "CIFS Share Paths"
            ExportTimestamp = $ExportTimestamp
        }
        $VolumeData | ConvertTo-Json -Depth 10 | Out-File -FilePath $VolumesFile -Encoding UTF8
        
        # Also create a simple text file for easy reference
        $VolumesTextFile = Join-Path $ExportDirectory "Share-Volumes.txt"
        "# Volumes extracted from CIFS share paths`n# Source: $SourceCluster -> $SourceSVM`n# Exported: $ExportTimestamp`n" | Out-File -FilePath $VolumesTextFile -Encoding UTF8
        $ShareVolumes | Sort-Object | ForEach-Object { $_ | Out-File -FilePath $VolumesTextFile -Append -Encoding UTF8 }
        
        $ExportSummary.ShareVolumes = $ShareVolumes | Sort-Object
        $ExportSummary.ExportedFiles += @($VolumesFile, $VolumesTextFile)
        Write-Log "[OK] Exported $($ShareVolumes.Count) volumes to: $VolumesFile"
        Write-Log "  Volumes: $($ShareVolumes -join ', ')"
    } else {
        Write-Log "[NOK] No volumes found from share paths" "WARNING"
    }

    # Step 4: Create Import Instructions File
    $InstructionsFile = Join-Path $ExportDirectory "IMPORT-INSTRUCTIONS.txt"
    $Instructions = @"
ONTAP CIFS CONFIGURATION IMPORT INSTRUCTIONS
=============================================

Export Information:
- Source Cluster: $SourceCluster
- Source SVM: $SourceSVM  
- Export Date: $ExportTimestamp
- Total Shares: $($CifsShares.Count)
- Dynamic Shares: $($DynamicShares.Count)
- Static Shares: $($StaticShares.Count)
- Total ACL Entries: $($ShareACLs.Count)
- Volumes from Shares: $($ShareVolumes.Count)

Files Exported:
$(($ExportSummary.ExportedFiles | ForEach-Object { "- " + (Split-Path $_ -Leaf) }) -join "`n")

To import this configuration:

1. Copy the entire export directory to the target system
2. Run the Import-ONTAPCIFSConfiguration.ps1 script with:
   .\Import-ONTAPCIFSConfiguration.ps1 -ImportPath "$ExportDirectory" -TargetCluster "target-cluster.domain.com" -TargetSVM "target_svm"

IMPORTANT NOTES:
- Ensure target SVM has CIFS protocol enabled and CIFS server configured
- Domain/workgroup configuration must be set up manually on target SVM
- This export contains only shares and ACLs, not volume or SVM configuration
- Target volumes must already exist and be accessible via the same paths
- Dynamic shares (with %w, %d variables) are fully supported and will be migrated
- Dynamic share variables are resolved by ONTAP at runtime based on user context

DYNAMIC SHARE REQUIREMENTS:
- For dynamic shares to function, target volumes must contain the expected directory structure
- SnapMirror should replicate all user directories (e.g., /vol_home/user1, /vol_home/user2)
- If user directories don't exist, users will get 'path not found' errors
- Consider running a final SnapMirror update before cutover to ensure latest directories

Generated on: $(Get-Date)
"@
    $Instructions | Out-File -FilePath $InstructionsFile -Encoding UTF8
    $ExportSummary.ExportedFiles += $InstructionsFile

    # Step 5: Create Export Summary
    $SummaryFile = Join-Path $ExportDirectory "Export-Summary.json"
    $ExportSummary | ConvertTo-Json -Depth 10 | Out-File -FilePath $SummaryFile -Encoding UTF8
    
    Write-Log "=== Export Completed Successfully ==="
    Write-Log "[OK] Export Summary: $SummaryFile"
    Write-Log "[OK] Import Instructions: $InstructionsFile"
    
} catch {
    Write-Log "Export failed with error: $($_.Exception.Message)" "ERROR"
    throw
} finally {
    if ($SourceController) {
        try {
            # Check if disconnect cmdlet is available
            if (Get-Command "Disconnect-NcController" -ErrorAction SilentlyContinue) {
                Disconnect-NcController $SourceController
                Write-Log "[OK] Disconnected from source cluster"
            } else {
                # No explicit disconnect cmdlet available - connection will close when session ends
                Write-Log "[OK] Source cluster connection will close automatically when session ends"
            }
        } catch {
            Write-Log "[NOK] Warning: Could not properly disconnect from source cluster: $($_.Exception.Message)" "WARNING"
        }
    }
}

# Display summary
Write-Host "`n=== Export Summary ===" -ForegroundColor Cyan
Write-Host "Source: $SourceCluster -> $SourceSVM" -ForegroundColor White
Write-Host "Export Directory: $ExportDirectory" -ForegroundColor Yellow
Write-Host "CIFS Shares: $($ExportSummary.Shares.Count)" -ForegroundColor Green
Write-Host "Share ACLs: $($ExportSummary.ShareACLs.Count)" -ForegroundColor Green
Write-Host "Share Volumes: $($ExportSummary.ShareVolumes.Count)" -ForegroundColor Green
Write-Host "Files Exported: $($ExportSummary.ExportedFiles.Count)" -ForegroundColor Green
Write-Host "`nNext Step: Run Import-ONTAPCIFSConfiguration.ps1 on target system" -ForegroundColor Cyan