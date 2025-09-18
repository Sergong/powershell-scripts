<#
.SYNOPSIS
    ONTAP Dynamic Share Readiness Validation Script
    
.DESCRIPTION
    Validates that target SVM volumes contain the necessary directory structures
    to support dynamic CIFS shares with variable substitution (%w, %d, etc.).
    
.PARAMETER TargetCluster
    Target ONTAP cluster management IP or FQDN
    
.PARAMETER TargetSVM
    Target SVM name to validate
    
.PARAMETER ImportPath
    Path to the CIFS export directory containing share configuration
    
.PARAMETER Credential
    PSCredential object for target ONTAP authentication
    
.PARAMETER SampleUsers
    Array of sample usernames to test dynamic path resolution
    
.PARAMETER WhatIf
    Show what would be validated without making connections
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$TargetCluster,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetSVM,
    
    [Parameter(Mandatory=$true)]
    [string]$ImportPath,
    
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,
    
    [Parameter(Mandatory=$false)]
    [string[]]$SampleUsers = @("testuser1", "testuser2"),
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
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
        $Username = Read-Host "Enter username for cluster: $TargetCluster"
        $SecurePassword = Read-Host "Enter password" -AsSecureString
        $Credential = New-Object System.Management.Automation.PSCredential($Username, $SecurePassword)
    } else {
        # Windows PowerShell
        $Credential = Get-Credential -Message "Enter credentials for target cluster: $TargetCluster"
    }
}

# Initialize logging
$LogFile = "DynamicShare-Validation-$(Get-Date -Format 'yyyy-MM-dd-HH-mm-ss').txt"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $LogEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry
}

Write-Log "=== Dynamic Share Readiness Validation Started ==="
Write-Log "Target: $TargetCluster -> $TargetSVM"
Write-Log "Import Path: $ImportPath"
Write-Log "Sample Users: $($SampleUsers -join ', ')"

try {
    # Load exported shares configuration
    $SharesFile = Join-Path $ImportPath "CIFS-Shares.json"
    if (!(Test-Path $SharesFile)) {
        throw "CIFS shares file not found: $SharesFile"
    }
    
    $ImportedShares = Get-Content -Path $SharesFile | ConvertFrom-Json
    Write-Log "[OK] Loaded $($ImportedShares.Count) CIFS shares from export"
    
    # Identify dynamic shares
    $DynamicShares = $ImportedShares | Where-Object { $_.Path -match '%[wdWD]' }
    $StaticShares = $ImportedShares | Where-Object { $_.Path -notmatch '%[wdWD]' }
    
    Write-Log "[OK] Found $($DynamicShares.Count) dynamic shares and $($StaticShares.Count) static shares"
    
    if ($DynamicShares.Count -eq 0) {
        Write-Log "[OK] No dynamic shares found - validation not needed"
        return
    }
    
    # Display dynamic shares
    Write-Log "Dynamic shares to validate:"
    foreach ($Share in $DynamicShares) {
        Write-Log "  - $($Share.ShareName): $($Share.Path)"
    }
    
    if ($WhatIf) {
        Write-Log "[WHATIF] Would connect to target cluster and validate volume structures"
        return
    }
    
    # Connect to target cluster
    Write-Log "Connecting to target cluster: $TargetCluster"
    $TargetController = Connect-NcController -Name $TargetCluster -Credential $Credential
    if (!$TargetController) {
        throw "Failed to connect to target cluster"
    }
    Write-Log "[OK] Connected to target cluster successfully"
    
    # Extract base volumes from dynamic share paths
    $VolumesToCheck = @{}
    foreach ($Share in $DynamicShares) {
        # Extract volume name from path (e.g., /vol_home/%w -> vol_home)
        if ($Share.Path -and $Share.Path.StartsWith('/')) {
            $PathParts = $Share.Path.Trim('/').Split('/')
            if ($PathParts.Length -gt 0 -and $PathParts[0] -ne "") {
                $VolumeName = $PathParts[0]
                if (!$VolumesToCheck.ContainsKey($VolumeName)) {
                    $VolumesToCheck[$VolumeName] = @()
                }
                $VolumesToCheck[$VolumeName] += $Share
            }
        }
    }
    
    Write-Log "Volumes to validate: $($VolumesToCheck.Keys -join ', ')"
    
    # Validate each volume
    $ValidationResults = @()
    foreach ($VolumeName in $VolumesToCheck.Keys) {
        Write-Log "Validating volume: $VolumeName"
        
        try {
            # Check if volume exists on target SVM
            $Volume = Get-NcVol -Controller $TargetController -VserverContext $TargetSVM -Name $VolumeName -ErrorAction SilentlyContinue
            if (!$Volume) {
                Write-Log "[NOK] Volume '$VolumeName' not found on target SVM" "ERROR"
                $ValidationResults += @{
                    Volume = $VolumeName
                    Status = "Volume Not Found"
                    Details = "Volume does not exist on target SVM"
                    Shares = $VolumesToCheck[$VolumeName]
                }
                continue
            }
            
            Write-Log "[OK] Volume '$VolumeName' found on target SVM"
            Write-Log "  Junction Path: $($Volume.VolumeIdAttributes.JunctionPath)"
            Write-Log "  Size: $([math]::Round($Volume.VolumeSpaceAttributes.Size/1GB,2)) GB"
            
            # For each sample user, check if path would resolve
            $MissingPaths = @()
            $ExistingPaths = @()
            
            foreach ($TestUser in $SampleUsers) {
                foreach ($Share in $VolumesToCheck[$VolumeName]) {
                    # Simulate path resolution
                    $TestPath = $Share.Path -replace '%w', $TestUser.ToLower()
                    $TestPath = $TestPath -replace '%W', $TestUser.ToUpper()
                    $TestPath = $TestPath -replace '%d', 'testdomain'
                    $TestPath = $TestPath -replace '%D', 'TESTDOMAIN'
                    
                    # Convert ONTAP path to actual file system path
                    $FileSystemPath = $TestPath.Replace('/', '\')
                    
                    Write-Log "  Testing path for user '$TestUser': $TestPath"
                    
                    # Note: We cannot directly test file system paths via PowerShell toolkit
                    # This would require additional file system access or ONTAP CLI commands
                    # For now, we'll log the expected paths that should exist
                    $ExistingPaths += @{
                        User = $TestUser
                        Share = $Share.ShareName
                        ExpectedPath = $TestPath
                    }
                }
            }
            
            $ValidationResults += @{
                Volume = $VolumeName
                Status = "Volume Found"
                Details = "Volume exists - manual verification of user directories recommended"
                Shares = $VolumesToCheck[$VolumeName]
                ExpectedPaths = $ExistingPaths
            }
            
        } catch {
            Write-Log "[NOK] Error validating volume '$VolumeName': $($_.Exception.Message)" "ERROR"
            $ValidationResults += @{
                Volume = $VolumeName
                Status = "Validation Error"
                Details = $_.Exception.Message
                Shares = $VolumesToCheck[$VolumeName]
            }
        }
    }
    
    # Generate validation report
    Write-Log ""
    Write-Log "=== VALIDATION SUMMARY ==="
    
    foreach ($Result in $ValidationResults) {
        Write-Log "Volume: $($Result.Volume) - Status: $($Result.Status)"
        Write-Log "  Details: $($Result.Details)"
        Write-Log "  Affected Shares: $($Result.Shares.ShareName -join ', ')"
        
        if ($Result.ExpectedPaths) {
            Write-Log "  Expected user directories (should exist for dynamic shares to work):"
            foreach ($Path in $Result.ExpectedPaths) {
                Write-Log "    User '$($Path.User)' -> $($Path.ExpectedPath)"
            }
        }
        Write-Log ""
    }
    
    # Recommendations
    Write-Log "=== RECOMMENDATIONS ==="
    Write-Log "1. Ensure SnapMirror replication is up-to-date before cutover"
    Write-Log "2. Manually verify that user directories exist in the target volumes:"
    
    foreach ($Result in $ValidationResults) {
        if ($Result.Status -eq "Volume Found" -and $Result.ExpectedPaths) {
            foreach ($Path in $Result.ExpectedPaths) {
                Write-Log "   Check: $($Path.ExpectedPath)"
            }
        }
    }
    
    Write-Log "3. If user directories are missing, consider:"
    Write-Log "   - Running a final SnapMirror update"
    Write-Log "   - Creating missing user directories manually"
    Write-Log "   - Using ONTAP CLI to verify directory contents"
    Write-Log "4. Test dynamic share access with actual user accounts after migration"
    
} catch {
    Write-Log "Validation failed with error: $($_.Exception.Message)" "ERROR"
    throw
} finally {
    if ($TargetController) {
        try {
            if (Get-Command "Disconnect-NcController" -ErrorAction SilentlyContinue) {
                Disconnect-NcController $TargetController
                Write-Log "[OK] Disconnected from target cluster"
            } else {
                Write-Log "[OK] Target cluster connection will close automatically when session ends"
            }
        } catch {
            Write-Log "[NOK] Warning: Could not properly disconnect from target cluster: $($_.Exception.Message)" "WARNING"
        }
    }
}

# Display summary
Write-Host "`n=== Dynamic Share Validation Summary ===" -ForegroundColor Cyan
Write-Host "Target: $TargetCluster -> $TargetSVM" -ForegroundColor White
Write-Host "Dynamic Shares Validated: $($DynamicShares.Count)" -ForegroundColor Green
Write-Host "Validation Log: $LogFile" -ForegroundColor Yellow
Write-Host "`nNext: Review log file and verify user directories exist in target volumes" -ForegroundColor Cyan