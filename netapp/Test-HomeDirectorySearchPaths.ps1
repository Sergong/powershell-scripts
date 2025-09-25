<#
.SYNOPSIS
Test script for home directory search path configuration

.DESCRIPTION
This script tests the configuration of home directory search paths for CIFS dynamic shares.
It tries multiple methods to set and verify home directory search paths.

.PARAMETER TargetCluster
Target ONTAP cluster management IP or FQDN

.PARAMETER TargetSVM
Target SVM name where home directory search paths will be configured

.PARAMETER TargetCredential
PSCredential object for target ONTAP authentication

.PARAMETER SearchPaths
Array of search paths to configure (e.g., @('/vol/home', '/vol/users'))
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$TargetCluster,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetSVM,
    
    [Parameter(Mandatory=$false)]
    [PSCredential]$TargetCredential,
    
    [Parameter(Mandatory=$false)]
    [string[]]$SearchPaths = @('/vol/home', '/vol/users')
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

try {
    # Connect to target cluster
    Write-Host "Connecting to target cluster: $TargetCluster" -ForegroundColor Cyan
    $TargetController = Connect-NcController -Name $TargetCluster -Credential $TargetCredential
    if (!$TargetController) {
        throw "Failed to connect to target cluster"
    }
    Write-Host "[OK] Connected to target cluster successfully" -ForegroundColor Green

    # Test 1: Check current home directory search paths
    Write-Host "`nTest 1: Checking current home directory search paths..." -ForegroundColor Yellow
    
    $CurrentSearchPaths = $null
    try {
        # Method 1: Direct cmdlet
        $CurrentSearchPaths = Get-NcCifsHomeDirectorySearchPath -Controller $TargetController -VserverContext $TargetSVM -ErrorAction SilentlyContinue
        if ($CurrentSearchPaths) {
            Write-Host "[OK] Current search paths (via cmdlet): $($CurrentSearchPaths -join ', ')" -ForegroundColor Green
        } else {
            Write-Host "[INFO] No search paths found via direct cmdlet" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[INFO] Direct cmdlet not available: $($_.Exception.Message)" -ForegroundColor Yellow
        
        # Method 2: Via CIFS options
        try {
            $CifsOptions = Get-NcCifsOption -Controller $TargetController -VserverContext $TargetSVM -ErrorAction SilentlyContinue
            if ($CifsOptions -and $CifsOptions.HomeDirectorySearchPaths) {
                $CurrentSearchPaths = $CifsOptions.HomeDirectorySearchPaths
                Write-Host "[OK] Current search paths (via CIFS options): $($CurrentSearchPaths -join ', ')" -ForegroundColor Green
            } else {
                Write-Host "[INFO] No search paths found via CIFS options" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "[INFO] CIFS options method not available: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Test 2: Set home directory search paths
    Write-Host "`nTest 2: Setting home directory search paths..." -ForegroundColor Yellow
    Write-Host "Search paths to set: $($SearchPaths -join ', ')" -ForegroundColor White
    
    $SetSuccessful = $false
    
    # Method 1: Direct cmdlet
    try {
        Write-Host "Attempting Method 1: Direct cmdlet..." -ForegroundColor Cyan
        foreach ($SearchPath in $SearchPaths) {
            Set-NcCifsHomeDirectorySearchPath -Controller $TargetController -VserverContext $TargetSVM -Path $SearchPath
            Write-Host "  ✅ Set search path: $SearchPath" -ForegroundColor Green
        }
        $SetSuccessful = $true
        Write-Host "[OK] Successfully set search paths via direct cmdlet" -ForegroundColor Green
    } catch {
        Write-Host "[NOK] Direct cmdlet failed: $($_.Exception.Message)" -ForegroundColor Red
        
        # Method 2: Via CIFS options
        try {
            Write-Host "Attempting Method 2: CIFS options..." -ForegroundColor Cyan
            Set-NcCifsOption -Controller $TargetController -VserverContext $TargetSVM -HomeDirectorySearchPaths $SearchPaths
            $SetSuccessful = $true
            Write-Host "[OK] Successfully set search paths via CIFS options" -ForegroundColor Green
        } catch {
            Write-Host "[NOK] CIFS options method failed: $($_.Exception.Message)" -ForegroundColor Red
            
            # Method 3: ZAPI
            try {
                Write-Host "Attempting Method 3: ZAPI..." -ForegroundColor Cyan
                $SearchPathsString = $SearchPaths -join ','
                $zapiXml = @"
<cifs-server-modify>
    <vserver>$TargetSVM</vserver>
    <home-directory-search-paths>$SearchPathsString</home-directory-search-paths>
</cifs-server-modify>
"@
                $result = Invoke-NcSystemApi -Controller $TargetController -Request $zapiXml
                $SetSuccessful = $true
                Write-Host "[OK] Successfully set search paths via ZAPI" -ForegroundColor Green
                Write-Host "ZAPI Result: $($result | ConvertTo-Json -Depth 2)" -ForegroundColor Gray
            } catch {
                Write-Host "[NOK] ZAPI method failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "[ERROR] All methods failed!" -ForegroundColor Red
            }
        }
    }

    # Test 3: Verify the configuration
    Write-Host "`nTest 3: Verifying configuration..." -ForegroundColor Yellow
    
    if ($SetSuccessful) {
        # Wait a moment for changes to take effect
        Start-Sleep -Seconds 3
        
        # Check configuration again
        $VerifySearchPaths = $null
        try {
            $VerifySearchPaths = Get-NcCifsHomeDirectorySearchPath -Controller $TargetController -VserverContext $TargetSVM -ErrorAction SilentlyContinue
        } catch {
            try {
                $CifsOptions = Get-NcCifsOption -Controller $TargetController -VserverContext $TargetSVM -ErrorAction SilentlyContinue
                if ($CifsOptions) {
                    $VerifySearchPaths = $CifsOptions.HomeDirectorySearchPaths
                }
            } catch {
                Write-Host "[WARNING] Could not verify configuration" -ForegroundColor Yellow
            }
        }
        
        if ($VerifySearchPaths) {
            Write-Host "[OK] Verification successful!" -ForegroundColor Green
            Write-Host "Configured search paths: $($VerifySearchPaths -join ', ')" -ForegroundColor White
            
            # Check if all paths were set correctly
            $AllPathsSet = $true
            foreach ($Path in $SearchPaths) {
                if ($VerifySearchPaths -notcontains $Path) {
                    Write-Host "  ❌ Missing path: $Path" -ForegroundColor Red
                    $AllPathsSet = $false
                } else {
                    Write-Host "  ✅ Path configured: $Path" -ForegroundColor Green
                }
            }
            
            if ($AllPathsSet) {
                Write-Host "[SUCCESS] All search paths configured correctly!" -ForegroundColor Green
            } else {
                Write-Host "[PARTIAL] Some search paths may not have been configured correctly" -ForegroundColor Yellow
            }
        } else {
            Write-Host "[WARNING] Could not retrieve search paths for verification" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[ERROR] Configuration not set - cannot verify" -ForegroundColor Red
    }

    # Test 4: Test dynamic share functionality (if paths are set)
    if ($SetSuccessful) {
        Write-Host "`nTest 4: Testing dynamic share functionality..." -ForegroundColor Yellow
        
        $TestShareName = "test_home_%w"
        $TestSharePath = "/vol/home/%w"
        
        # Clean up any existing test share
        try {
            Remove-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShareName -Confirm:$false -ErrorAction SilentlyContinue
        } catch {}
        
        try {
            # Create a test dynamic share
            $ShareParams = @{
                Controller = $TargetController
                VserverContext = $TargetSVM
                Name = $TestShareName
                Path = $TestSharePath
                HomeDirectory = $true
            }
            
            Add-NcCifsShare @ShareParams
            Write-Host "[OK] Created test dynamic share: $TestShareName" -ForegroundColor Green
            
            # Verify the share
            $TestShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShareName
            if ($TestShare) {
                Write-Host "Share details:" -ForegroundColor White
                Write-Host "  Name: $($TestShare.ShareName)" -ForegroundColor White
                Write-Host "  Path: $($TestShare.Path)" -ForegroundColor White
                Write-Host "  Properties: $($TestShare.ShareProperties -join ', ')" -ForegroundColor White
                
                if ($TestShare.ShareProperties -contains "homedirectory") {
                    Write-Host "  ✅ HomeDirectory property is set correctly" -ForegroundColor Green
                } else {
                    Write-Host "  ❌ HomeDirectory property is missing!" -ForegroundColor Red
                }
            }
            
            # Clean up test share
            Remove-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShareName -Confirm:$false
            Write-Host "[INFO] Test share cleaned up" -ForegroundColor Gray
            
        } catch {
            Write-Host "[NOK] Failed to test dynamic share: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host "`n=== Home Directory Search Path Test Summary ===" -ForegroundColor Cyan
    if ($SetSuccessful) {
        Write-Host "✅ Configuration successful - Home directory search paths are set" -ForegroundColor Green
        Write-Host "🏠 Dynamic shares should now work properly" -ForegroundColor Green
        Write-Host "📋 The main takeover script should handle this configuration automatically" -ForegroundColor Yellow
    } else {
        Write-Host "❌ Configuration failed - Dynamic shares may not work" -ForegroundColor Red
        Write-Host "💡 Check ONTAP version compatibility and permissions" -ForegroundColor Yellow
    }
    
} catch {
    Write-Host "[ERROR] Test failed: $($_.Exception.Message)" -ForegroundColor Red
    throw
} finally {
    # Cleanup connection
    if ($TargetController) {
        try {
            if (Get-Command "Disconnect-NcController" -ErrorAction SilentlyContinue) {
                Disconnect-NcController $TargetController
            }
        } catch {
            Write-Host "[WARNING] Could not disconnect cleanly" -ForegroundColor Yellow
        }
    }
}