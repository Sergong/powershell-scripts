<#
.SYNOPSIS
    ONTAP 9.13 CIFS SVM Configuration Export Script
    
.DESCRIPTION
    Collects all volume, CIFS share, and permission information from a source ONTAP cluster
    and exports the data to structured files for later import to a target cluster.
    
.PARAMETER SourceCluster
    Source ONTAP cluster management IP or FQDN
    
.PARAMETER SourceSVM
    Source SVM name containing the CIFS shares
    
.PARAMETER Credential
    PSCredential object for source ONTAP authentication
    
.PARAMETER ExportPath
    Path to store exported configuration files
    
.PARAMETER IncludeSnapMirrorInfo
    Include SnapMirror relationship information in export
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourceCluster,
    
    [Parameter(Mandatory=$true)]
    [string]$SourceSVM,
    
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,
    
    [Parameter(Mandatory=$false)]
    [string]$ExportPath = "C:\ONTAP_Export",
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludeSnapMirrorInfo
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
    $Credential = Get-Credential -Message "Enter credentials for source cluster: $SourceCluster"
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
    Volumes = @()
    Shares = @()
    ShareACLs = @()
    CifsServer = $null
    SnapMirrorRelationships = @()
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

    # Step 1: Export SVM Information
    Write-Log "Collecting SVM information..."
    $SVMInfo = Get-NcVserver -Controller $SourceController -Name $SourceSVM
    $SVMExportFile = Join-Path $ExportDirectory "SVM-Info.json"
    $SVMInfo | ConvertTo-Json -Depth 10 | Out-File -FilePath $SVMExportFile -Encoding UTF8
    $ExportSummary.ExportedFiles += $SVMExportFile
    Write-Log "[OK] SVM information exported to: $SVMExportFile"

    # Step 2: Export CIFS Server Configuration
    Write-Log "Collecting CIFS server configuration..."
    try {
        $CifsServer = Get-NcCifsServer -Controller $SourceController -VserverContext $SourceSVM
        $CifsServerFile = Join-Path $ExportDirectory "CIFS-Server.json"
        $CifsServer | ConvertTo-Json -Depth 10 | Out-File -FilePath $CifsServerFile -Encoding UTF8
        $ExportSummary.CifsServer = $CifsServer
        $ExportSummary.ExportedFiles += $CifsServerFile
        Write-Log "[OK] CIFS server configuration exported to: $CifsServerFile"
        Write-Log "  - CIFS Server Name: $($CifsServer.CifsServer)"
        Write-Log "  - Domain: $($CifsServer.Domain)"
        Write-Log "  - Workgroup: $($CifsServer.Workgroup)"
    } catch {
        Write-Log "[NOK] Could not retrieve CIFS server information: $($_.Exception.Message)" "WARNING"
    }

    # Step 3: Export CIFS Shares
    Write-Log "Collecting CIFS shares..."
    $CifsShares = Get-NcCifsShare -Controller $SourceController -VserverContext $SourceSVM
    $SharesFile = Join-Path $ExportDirectory "CIFS-Shares.json"
    $SharesFileXML = Join-Path $ExportDirectory "CIFS-Shares.xml"
    
    # Export in both JSON and XML formats for compatibility
    $CifsShares | ConvertTo-Json -Depth 10 | Out-File -FilePath $SharesFile -Encoding UTF8
    $CifsShares | Export-Clixml -Path $SharesFileXML
    
    $ExportSummary.Shares = $CifsShares
    $ExportSummary.ExportedFiles += @($SharesFile, $SharesFileXML)
    Write-Log "[OK] Found $($CifsShares.Count) CIFS shares"
    Write-Log "[OK] CIFS shares exported to: $SharesFile"

    # Export detailed share information to CSV for review
    $SharesCSV = Join-Path $ExportDirectory "CIFS-Shares-Details.csv"
    $CifsShares | Select-Object ShareName, Path, Comment, ShareProperties, SymlinkProperties, VscanProfile | Export-Csv -Path $SharesCSV -NoTypeInformation
    $ExportSummary.ExportedFiles += $SharesCSV
    Write-Log "[OK] CIFS shares details exported to: $SharesCSV"

    # Step 4: Export CIFS Share ACLs
    Write-Log "Collecting CIFS share ACLs..."
    $ShareACLs = Get-NcCifsShareAcl -Controller $SourceController -VserverContext $SourceSVM
    $ACLsFile = Join-Path $ExportDirectory "CIFS-ShareACLs.json"
    $ACLsFileXML = Join-Path $ExportDirectory "CIFS-ShareACLs.xml"
    
    $ShareACLs | ConvertTo-Json -Depth 10 | Out-File -FilePath $ACLsFile -Encoding UTF8
    $ShareACLs | Export-Clixml -Path $ACLsFileXML
    
    $ExportSummary.ShareACLs = $ShareACLs
    $ExportSummary.ExportedFiles += @($ACLsFile, $ACLsFileXML)
    Write-Log "[OK] Found $($ShareACLs.Count) share ACL entries"
    Write-Log "[OK] Share ACLs exported to: $ACLsFile"

    # Export ACLs to CSV for review
    $ACLsCSV = Join-Path $ExportDirectory "CIFS-ShareACLs-Details.csv"
    $ShareACLs | Select-Object Share, UserOrGroup, UserGroupType, Permission | Export-Csv -Path $ACLsCSV -NoTypeInformation
    $ExportSummary.ExportedFiles += $ACLsCSV

    # Step 5: Export Volume Information
    Write-Log "Collecting volume information for share paths..."
    $ShareVolumes = $CifsShares | ForEach-Object { 
        $_.Path.Split('/')[1] 
    } | Sort-Object -Unique | Where-Object { $_ -ne "" }
    
    $VolumeInfo = @()
    foreach ($VolumeName in $ShareVolumes) {
        try {
            $Volume = Get-NcVol -Controller $SourceController -VserverContext $SourceSVM -Name $VolumeName
            if ($Volume) {
                $VolumeInfo += $Volume
                Write-Log "[OK] Collected information for volume: $VolumeName"
            }
        } catch {
            Write-Log "[NOK] Could not retrieve information for volume: $VolumeName" "WARNING"
        }
    }
    
    $VolumesFile = Join-Path $ExportDirectory "Volumes-Info.json"
    $VolumeInfo | ConvertTo-Json -Depth 10 | Out-File -FilePath $VolumesFile -Encoding UTF8
    $ExportSummary.Volumes = $VolumeInfo
    $ExportSummary.ExportedFiles += $VolumesFile
    Write-Log "[OK] Volume information exported to: $VolumesFile"

    # Export volume details to CSV
    $VolumesCSV = Join-Path $ExportDirectory "Volumes-Details.csv"
    $VolumeInfo | Select-Object Name, @{Name='SizeGB';Expression={[math]::Round($_.VolumeSpaceAttributes.Size/1GB,2)}}, VolumeStateAttributes, SecurityStyle, JunctionPath | Export-Csv -Path $VolumesCSV -NoTypeInformation
    $ExportSummary.ExportedFiles += $VolumesCSV

    # Step 6: Export SnapMirror Relationships (if requested)
    if ($IncludeSnapMirrorInfo) {
        Write-Log "Collecting SnapMirror relationship information..."
        $SnapMirrorRelationships = @()
        
        foreach ($VolumeName in $ShareVolumes) {
            try {
                $SMRelation = Get-NcSnapmirror -Controller $SourceController -Source "$($SourceSVM):$VolumeName"
                if ($SMRelation) {
                    $SnapMirrorRelationships += $SMRelation
                    Write-Log "[OK] Found SnapMirror relationship for volume: $VolumeName -> $($SMRelation.Destination)"
                }
            } catch {
                Write-Log "[NOK] Could not retrieve SnapMirror info for volume: $VolumeName" "WARNING"
            }
        }
        
        if ($SnapMirrorRelationships.Count -gt 0) {
            $SnapMirrorFile = Join-Path $ExportDirectory "SnapMirror-Relationships.json"
            $SnapMirrorRelationships | ConvertTo-Json -Depth 10 | Out-File -FilePath $SnapMirrorFile -Encoding UTF8
            $ExportSummary.SnapMirrorRelationships = $SnapMirrorRelationships
            $ExportSummary.ExportedFiles += $SnapMirrorFile
            Write-Log "[OK] SnapMirror relationships exported to: $SnapMirrorFile"
            
            # Export SnapMirror details to CSV
            $SnapMirrorCSV = Join-Path $ExportDirectory "SnapMirror-Details.csv"
            $SnapMirrorRelationships | Select-Object Source, Destination, Status, Policy, Schedule | Export-Csv -Path $SnapMirrorCSV -NoTypeInformation
            $ExportSummary.ExportedFiles += $SnapMirrorCSV
        } else {
            Write-Log "[NOK] No SnapMirror relationships found for share volumes" "WARNING"
        }
    }

    # Step 7: Create Import Instructions File
    $InstructionsFile = Join-Path $ExportDirectory "IMPORT-INSTRUCTIONS.txt"
    $Instructions = @"
ONTAP CIFS CONFIGURATION IMPORT INSTRUCTIONS
=============================================

Export Information:
- Source Cluster: $SourceCluster
- Source SVM: $SourceSVM  
- Export Date: $ExportTimestamp
- Total Shares: $($CifsShares.Count)
- Total ACL Entries: $($ShareACLs.Count)
- Total Volumes: $($VolumeInfo.Count)

Files Exported:
$(($ExportSummary.ExportedFiles | ForEach-Object { "- " + (Split-Path $_ -Leaf) }) -join "`n")

To import this configuration:

1. Copy the entire export directory to the target system
2. Run the Import-ONTAPCIFSConfiguration.ps1 script with:
   .\Import-ONTAPCIFSConfiguration.ps1 -ImportPath "$ExportDirectory" -TargetCluster "target-cluster.domain.com" -TargetSVM "target_svm"

IMPORTANT NOTES:
- Ensure SnapMirror relationships are broken before import
- Verify target SVM has CIFS protocol enabled
- Domain/workgroup configuration may need manual setup
- Review CSV files for detailed configuration before import

Generated on: $(Get-Date)
"@
    $Instructions | Out-File -FilePath $InstructionsFile -Encoding UTF8
    $ExportSummary.ExportedFiles += $InstructionsFile

    # Step 8: Create Export Summary
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
            Disconnect-NcController -Controller $SourceController
            Write-Log "[OK] Disconnected from source cluster"
        } catch {
            Write-Log "[NOK] Warning: Could not properly disconnect from source cluster" "WARNING"
        }
    }
}

# Display summary
Write-Host "`n=== Export Summary ===" -ForegroundColor Cyan
Write-Host "Source: $SourceCluster -> $SourceSVM" -ForegroundColor White
Write-Host "Export Directory: $ExportDirectory" -ForegroundColor Yellow
Write-Host "CIFS Shares: $($ExportSummary.Shares.Count)" -ForegroundColor Green
Write-Host "Share ACLs: $($ExportSummary.ShareACLs.Count)" -ForegroundColor Green  
Write-Host "Volumes: $($ExportSummary.Volumes.Count)" -ForegroundColor Green
Write-Host "Files Exported: $($ExportSummary.ExportedFiles.Count)" -ForegroundColor Green
Write-Host "`nNext Step: Run Import-ONTAPCIFSConfiguration.ps1 on target system" -ForegroundColor Cyan