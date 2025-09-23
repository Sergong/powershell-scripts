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
    
    # Debug: Show properties of first SnapMirror relationship to understand the object structure
    if ($AllSnapMirrors.Count -gt 0) {
        Write-Host "=== DEBUG: SNAPMIRROR OBJECT PROPERTIES ===" -ForegroundColor Yellow
        $FirstSM = $AllSnapMirrors[0]
        Write-Host "Available properties on SnapMirror object:" -ForegroundColor Yellow
        
        # Get all properties and their values
        $Properties = $FirstSM | Get-Member -MemberType Property | ForEach-Object { $_.Name }
        foreach ($PropName in $Properties | Sort-Object) {
            try {
                $PropValue = $FirstSM.$PropName
                $PropType = if ($PropValue -ne $null) { $PropValue.GetType().Name } else { "null" }
                Write-Host "  $PropName ($PropType) = $PropValue" -ForegroundColor Gray
            }
            catch {
                Write-Host "  $PropName = <Error accessing property>" -ForegroundColor Red
            }
        }
        
        Write-Host ""
        Write-Host "Looking for likely source/destination properties:" -ForegroundColor Yellow
        $LikelyProps = $Properties | Where-Object { 
            $_ -match "source|destination|volume|path|location" 
        }
        foreach ($PropName in $LikelyProps) {
            try {
                $PropValue = $FirstSM.$PropName
                Write-Host "  CANDIDATE: $PropName = $PropValue" -ForegroundColor Cyan
            }
            catch {
                Write-Host "  CANDIDATE: $PropName = <Error>" -ForegroundColor Red
            }
        }
        Write-Host ""
    }
    
    # Display all SnapMirror relationships
    Write-Host "=== ALL SNAPMIRROR RELATIONSHIPS ===" -ForegroundColor Cyan
    
    $Counter = 0
    foreach ($SM in $AllSnapMirrors) {
        $Counter++
        Write-Host "SnapMirror Relationship #$($Counter):" -ForegroundColor White
        
        # Try to find source and destination properties by checking common property patterns
        $SourceProp = $null
        $DestProp = $null
        $StatusProp = $null
        
        # Get all properties of this object
        $AllProps = $SM | Get-Member -MemberType Property | ForEach-Object { $_.Name }
        
        # Look for source properties
        $SourceCandidates = @('SourceVolume', 'SourcePath', 'SourceLocation', 'Source', 'SourceCluster', 'SourceVserver')
        foreach ($candidate in $SourceCandidates) {
            if ($AllProps -contains $candidate -and $SM.$candidate -and $SM.$candidate -ne $true -and $SM.$candidate -ne $false) {
                $SourceProp = $SM.$candidate
                Write-Host "  Source ($candidate): $SourceProp" -ForegroundColor Green
                break
            }
        }
        
        # Look for destination properties
        $DestCandidates = @('DestinationVolume', 'DestinationPath', 'DestinationLocation', 'Destination', 'DestinationCluster', 'DestinationVserver')
        foreach ($candidate in $DestCandidates) {
            if ($AllProps -contains $candidate -and $SM.$candidate -and $SM.$candidate -ne $true -and $SM.$candidate -ne $false) {
                $DestProp = $SM.$candidate
                Write-Host "  Destination ($candidate): $DestProp" -ForegroundColor Green
                break
            }
        }
        
        # Look for status properties
        $StatusCandidates = @('Status', 'RelationshipStatus', 'MirrorState', 'State')
        foreach ($candidate in $StatusCandidates) {
            if ($AllProps -contains $candidate -and $SM.$candidate) {
                $StatusProp = $SM.$candidate
                $StatusColor = switch ($StatusProp.ToString()) {
                    "Idle" { "Green" }
                    "Transferring" { "Yellow" }
                    "Broken-off" { "Red" }
                    "Quiesced" { "Yellow" }
                    default { "White" }
                }
                Write-Host "  Status ($candidate): $StatusProp" -ForegroundColor $StatusColor
                break
            }
        }
        
        # Show other interesting properties if available
        $InterestingProps = @('Policy', 'Type', 'LagTime', 'Vserver', 'Volume')
        foreach ($prop in $InterestingProps) {
            if ($AllProps -contains $prop -and $SM.$prop) {
                Write-Host "  $prop`: $($SM.$prop)" -ForegroundColor Gray
            }
        }
        
        # If we couldn't find obvious source/dest, show a few key properties for debugging
        if (-not $SourceProp -or -not $DestProp) {
            Write-Host "  DEBUG - Key properties:" -ForegroundColor Yellow
            foreach ($prop in ($AllProps | Sort-Object)) {
                $value = $SM.$prop
                if ($value -and $value -ne $true -and $value -ne $false -and $value.ToString().Length -lt 100) {
                    Write-Host "    $prop = $value" -ForegroundColor Gray
                }
            }
        }
        
        Write-Host ""
    }
    
    # Filter for specific SVM if provided
    if ($SVM) {
        Write-Host "=== SNAPMIRROR RELATIONSHIPS FOR SVM: $SVM ===" -ForegroundColor Cyan
        
        # All relationships for the SVM
        $SVMSnapMirrors = $AllSnapMirrors | Where-Object { $_.Destination -like "$($SVM):*" }
        
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
                $Count = ($AllSnapMirrors | Where-Object { $_.Destination -like "$($DestSVM):*" }).Count
                Write-Host "  - $DestSVM ($Count relationships)" -ForegroundColor Yellow
            }
        }
    }
    
    # Show recommendations
    Write-Host "`n=== RECOMMENDATIONS ===" -ForegroundColor Cyan
    if ($SVM) {
        $ActiveForSVM = $AllSnapMirrors | Where-Object { $_.Destination -like "$($SVM):*" -and $_.Status -ne "Broken-off" }
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