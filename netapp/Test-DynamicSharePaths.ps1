<#
.SYNOPSIS
Test script specifically for dynamic share path handling with user variables

.DESCRIPTION
This script tests the creation of dynamic CIFS shares with user variables like %w
to ensure the paths are preserved correctly and HomeDirectory property is set.

.PARAMETER TargetCluster
Target ONTAP cluster management IP or FQDN

.PARAMETER TargetSVM
Target SVM name where shares will be created

.PARAMETER TargetCredential
PSCredential object for target ONTAP authentication
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$TargetCluster,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetSVM,
    
    [Parameter(Mandatory=$false)]
    [PSCredential]$TargetCredential
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

    # Test dynamic share scenarios
    $TestShares = @(
        @{
            Name = "home_%w"
            Path = "/home/%w"
            Description = "Windows username variable"
        },
        @{
            Name = "user_%d_%w"
            Path = "/users/%d/%w"
            Description = "Domain and username variables"
        },
        @{
            Name = "unix_%u"
            Path = "/unix_home/%u"
            Description = "UNIX username variable"
        }
    )
    
    Write-Host "`nTesting Dynamic Share Path Handling..." -ForegroundColor Yellow
    
    foreach ($TestShare in $TestShares) {
        Write-Host "`n--- Testing: $($TestShare.Description) ---" -ForegroundColor Cyan
        Write-Host "Share Name: $($TestShare.Name)" -ForegroundColor White
        Write-Host "Share Path: $($TestShare.Path)" -ForegroundColor White
        
        # Clean up any existing test share
        $ExistingShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShare.Name -ErrorAction SilentlyContinue
        if ($ExistingShare) {
            Write-Host "[INFO] Removing existing test share..." -ForegroundColor Yellow
            Remove-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShare.Name -Confirm:$false
        }
        
        # Test 1: Create share using individual parameters (ONTAP 9.17 approach)
        Write-Host "`nTest 1: Creating with individual parameters (-HomeDirectory $true)..." -ForegroundColor Yellow
        
        try {
            $ShareParams = @{
                Controller = $TargetController
                VserverContext = $TargetSVM
                Name = $TestShare.Name
                Path = $TestShare.Path
                HomeDirectory = $true
            }
            
            Write-Host "Parameters being used:" -ForegroundColor Gray
            Write-Host "  Name: '$($ShareParams.Name)'" -ForegroundColor Gray
            Write-Host "  Path: '$($ShareParams.Path)'" -ForegroundColor Gray
            Write-Host "  HomeDirectory: $($ShareParams.HomeDirectory)" -ForegroundColor Gray
            
            Add-NcCifsShare @ShareParams
            Write-Host "[OK] Share created successfully with individual parameters!" -ForegroundColor Green
            
            # Verify the created share
            $CreatedShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShare.Name
            if ($CreatedShare) {
                Write-Host "`nVerification Results:" -ForegroundColor White
                Write-Host "  Created Name: '$($CreatedShare.ShareName)'" -ForegroundColor White
                Write-Host "  Created Path: '$($CreatedShare.Path)'" -ForegroundColor White
                Write-Host "  Share Properties: '$($CreatedShare.ShareProperties -join ', ')'" -ForegroundColor White
                
                # Path verification
                if ($CreatedShare.Path -eq $TestShare.Path) {
                    Write-Host "  ✅ Path Verification: PASSED" -ForegroundColor Green
                } else {
                    Write-Host "  ❌ Path Verification: FAILED" -ForegroundColor Red
                    Write-Host "    Expected: '$($TestShare.Path)'" -ForegroundColor Red
                    Write-Host "    Actual: '$($CreatedShare.Path)'" -ForegroundColor Red
                }
                
                # HomeDirectory property verification
                if ($CreatedShare.ShareProperties -contains "homedirectory") {
                    Write-Host "  ✅ HomeDirectory Property: PRESENT" -ForegroundColor Green
                } else {
                    Write-Host "  ❌ HomeDirectory Property: MISSING" -ForegroundColor Red
                }
                
                # User variable verification
                if ($CreatedShare.Path -match '%[wdWDuU]') {
                    Write-Host "  ✅ User Variables: PRESERVED" -ForegroundColor Green
                } else {
                    Write-Host "  ❌ User Variables: LOST OR MODIFIED" -ForegroundColor Red
                }
                
            } else {
                Write-Host "  ❌ Could not retrieve created share for verification" -ForegroundColor Red
            }
            
        } catch {
            Write-Host "[NOK] Failed with individual parameters: $($_.Exception.Message)" -ForegroundColor Red
            
            # Fallback: Try with ShareProperties array
            Write-Host "`nFallback: Trying with ShareProperties array..." -ForegroundColor Yellow
            
            try {
                $ShareParamsFallback = @{
                    Controller = $TargetController
                    VserverContext = $TargetSVM
                    Name = $TestShare.Name
                    Path = $TestShare.Path
                    ShareProperties = @('homedirectory')
                }
                
                Add-NcCifsShare @ShareParamsFallback
                Write-Host "[OK] Share created successfully with ShareProperties array!" -ForegroundColor Green
                
                # Verify fallback result
                $CreatedShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShare.Name
                if ($CreatedShare) {
                    Write-Host "`nFallback Verification:" -ForegroundColor White
                    Write-Host "  Path: '$($CreatedShare.Path)'" -ForegroundColor White
                    Write-Host "  Properties: '$($CreatedShare.ShareProperties -join ', ')'" -ForegroundColor White
                    
                    if ($CreatedShare.Path -eq $TestShare.Path -and $CreatedShare.ShareProperties -contains "homedirectory") {
                        Write-Host "  ✅ Fallback method worked correctly" -ForegroundColor Green
                    }
                }
                
            } catch {
                Write-Host "[NOK] Both methods failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        
        # Clean up test share
        try {
            Remove-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShare.Name -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "[INFO] Test share cleaned up" -ForegroundColor Gray
        } catch {
            Write-Host "[WARNING] Could not clean up test share" -ForegroundColor Yellow
        }
    }
    
    Write-Host "`n=== Dynamic Share Path Test Summary ===" -ForegroundColor Cyan
    Write-Host "✅ Test completed - check results above for each share type" -ForegroundColor Green
    Write-Host "💡 The main script now includes enhanced debugging for dynamic shares" -ForegroundColor Yellow
    Write-Host "🔍 Look for [VERIFY] messages in the main script logs to see path preservation" -ForegroundColor Yellow
    
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