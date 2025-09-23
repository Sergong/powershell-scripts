<#
.SYNOPSIS
    Debug script to help troubleshoot SnapMirror discovery issues

.DESCRIPTION
    This script connects to an ONTAP cluster and lists all SnapMirror relationships
    to help debug SnapMirror discovery issues in the main migration script.

.PARAMETER Cluster
    ONTAP cluster management IP or FQDN

.PARAMETER SVM
    SVM name to examine (optional - shows all if not specified)

.PARAMETER Credential
    PSCredential object for ONTAP authentication

.EXAMPLE
    .\Debug-SnapMirrorDiscovery.ps1 -Cluster "cluster.domain.com" -SVM "target_svm"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Cluster,
    
    [Parameter(Mandatory=$false)]
    [string]$SVM,
    
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential
)

# Import NetApp PowerShell Toolkit
try {
    Import-Module NetApp.ONTAP -ErrorAction Stop
    Write-Host "[OK] NetApp PowerShell Toolkit loaded successfully" -ForegroundColor Green
} catch {
    Write-Error "Failed to import NetApp.ONTAP module. Please install the NetApp PowerShell Toolkit."
    exit 1
}

# Get credentials if not provided
if (-not $Credential) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell 7 compatible credential input
        $Username = Read-Host "Enter username for cluster: $Cluster"
        $SecurePassword = Read-Host "Enter password" -AsSecureString
        $Credential = New-Object System.Management.Automation.PSCredential($Username, $SecurePassword)
    } else {
        # Windows PowerShell
        $Credential = Get-Credential -Message "Enter credentials for cluster: $Cluster"
    }
}

try {
    # Connect to cluster
    Write-Host "Connecting to cluster: $Cluster" -ForegroundColor Yellow
    $Controller = Connect-NcController -Name $Cluster -Credential $Credential
    if (!$Controller) {
        throw "Failed to connect to cluster"
    }
    Write-Host "[OK] Connected to cluster successfully" -ForegroundColor Green

    # Get all SnapMirror relationships
    Write-Host "`nRetrieving all SnapMirror relationships..." -ForegroundColor Yellow
    $AllSnapMirrors = Get-NcSnapmirror -Controller $Controller
    
    if (!$AllSnapMirrors -or $AllSnapMirrors.Count -eq 0) {
        Write-Host "[WARNING] No SnapMirror relationships found on cluster: $Cluster" -ForegroundColor Yellow
        exit 0
    }
    
    Write-Host "[OK] Found $($AllSnapMirrors.Count) total SnapMirror relationships" -ForegroundColor Green
    Write-Host ""
    
    # Display all SnapMirror relationships
    Write-Host "=== ALL SNAPMIRROR RELATIONSHIPS ===" -ForegroundColor Cyan
    foreach ($SM in $AllSnapMirrors | Sort-Object Destination) {
        $StatusColor = switch ($SM.Status) {
            "Idle" { "Green" }
            "Transferring" { "Yellow" }
            "Broken-off" { "Red" }
            "Quiesced" { "Yellow" }
            default { "White" }
        }
        
        Write-Host "SnapMirror: $($SM.Source) -> $($SM.Destination)" -ForegroundColor White
        Write-Host "  Status: $($SM.Status)" -ForegroundColor $StatusColor
        Write-Host "  Relationship Status: $($SM.RelationshipStatus)" -ForegroundColor Gray
        Write-Host "  Policy: $($SM.Policy)" -ForegroundColor Gray
        Write-Host "  Type: $($SM.Type)" -ForegroundColor Gray
        if ($SM.LagTime) {
            Write-Host "  Lag Time: $($SM.LagTime)" -ForegroundColor Gray
        }
        Write-Host ""
    }
    
    # Filter for specific SVM if provided
    if ($SVM) {
        Write-Host "=== SNAPMIRROR RELATIONSHIPS FOR SVM: $SVM ===" -ForegroundColor Cyan
        
        # All relationships for the SVM
        $SVMSnapMirrors = $AllSnapMirrors | Where-Object { $_.Destination -like "${SVM}:*" }
        
        if ($SVMSnapMirrors) {
            Write-Host "[OK] Found $($SVMSnapMirrors.Count) SnapMirror relationships for SVM: $SVM" -ForegroundColor Green
            
            # Active relationships (not broken-off)
            $ActiveSVMSnapMirrors = $SVMSnapMirrors | Where-Object { $_.Status -ne "Broken-off" }
            $BrokenSVMSnapMirrors = $SVMSnapMirrors | Where-Object { $_.Status -eq "Broken-off" }
            
            Write-Host "`n--- ACTIVE RELATIONSHIPS (NOT BROKEN) ---" -ForegroundColor Green
            if ($ActiveSVMSnapMirrors) {
                Write-Host "Found $($ActiveSVMSnapMirrors.Count) active SnapMirror relationships:" -ForegroundColor Green
                foreach ($SM in $ActiveSVMSnapMirrors | Sort-Object Destination) {
                    $VolumeName = ($SM.Destination -split ':')[1]
                    $StatusColor = switch ($SM.Status) {
                        "Idle" { "Green" }
                        "Transferring" { "Yellow" }  
                        "Quiesced" { "Yellow" }
                        default { "White" }
                    }
                    Write-Host "  - Volume: $VolumeName (Status: $($SM.Status), Source: $($SM.Source))" -ForegroundColor $StatusColor
                }
                
                # These are the volumes that would be discovered by the migration script
                $DiscoverableVolumes = $ActiveSVMSnapMirrors | ForEach-Object { ($_.Destination -split ':')[1] }
                Write-Host "`n✅ VOLUMES DISCOVERABLE BY MIGRATION SCRIPT:" -ForegroundColor Green
                Write-Host "   $($DiscoverableVolumes -join ', ')" -ForegroundColor Green
                
            } else {
                Write-Host "❌ No active SnapMirror relationships found for SVM: $SVM" -ForegroundColor Red
            }
            
            Write-Host "`n--- BROKEN RELATIONSHIPS ---" -ForegroundColor Red
            if ($BrokenSVMSnapMirrors) {
                Write-Host "Found $($BrokenSVMSnapMirrors.Count) broken SnapMirror relationships:" -ForegroundColor Yellow
                foreach ($SM in $BrokenSVMSnapMirrors | Sort-Object Destination) {
                    $VolumeName = ($SM.Destination -split ':')[1]
                    Write-Host "  - Volume: $VolumeName (Status: $($SM.Status), Source: $($SM.Source))" -ForegroundColor Red
                }
            } else {
                Write-Host "No broken SnapMirror relationships found for SVM: $SVM" -ForegroundColor Green
            }
            
        } else {
            Write-Host "❌ No SnapMirror relationships found for SVM: $SVM" -ForegroundColor Red
            
            # Show available destination SVMs
            Write-Host "`n=== AVAILABLE DESTINATION SVMs ===" -ForegroundColor Yellow
            $DestinationSVMs = $AllSnapMirrors | ForEach-Object { ($_.Destination -split ':')[0] } | Sort-Object | Get-Unique
            Write-Host "Available destination SVMs in SnapMirror relationships:" -ForegroundColor Yellow
            foreach ($DestSVM in $DestinationSVMs) {
                $Count = ($AllSnapMirrors | Where-Object { $_.Destination -like "${DestSVM}:*" }).Count
                Write-Host "  - $DestSVM ($Count relationships)" -ForegroundColor Yellow
            }
        }
    }
    
    # Show recommendations
    Write-Host "`n=== RECOMMENDATIONS ===" -ForegroundColor Cyan
    if ($SVM) {
        $ActiveForSVM = $AllSnapMirrors | Where-Object { $_.Destination -like "${SVM}:*" -and $_.Status -ne "Broken-off" }
        if ($ActiveForSVM) {
            Write-Host "✅ SVM '$SVM' has $($ActiveForSVM.Count) active SnapMirror relationships" -ForegroundColor Green
            Write-Host "   The migration script should discover these automatically" -ForegroundColor Green
        } else {
            Write-Host "❌ SVM '$SVM' has no active SnapMirror relationships" -ForegroundColor Red
            Write-Host "   Check:" -ForegroundColor Red
            Write-Host "   1. SVM name spelling is correct" -ForegroundColor Red
            Write-Host "   2. SnapMirror relationships exist and are not broken" -ForegroundColor Red
            Write-Host "   3. You're connecting to the correct target cluster" -ForegroundColor Red
        }
    } else {
        Write-Host "✅ Found $($AllSnapMirrors.Count) total SnapMirror relationships" -ForegroundColor Green
        Write-Host "   Run with -SVM parameter to filter for specific SVM" -ForegroundColor Yellow
    }

} catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    throw
} finally {
    if ($Controller) {
        try {
            if (Get-Command "Disconnect-NcController" -ErrorAction SilentlyContinue) {
                Disconnect-NcController $Controller
                Write-Host "[OK] Disconnected from cluster" -ForegroundColor Green
            }
        } catch {
            # Ignore disconnect errors
        }
    }
}