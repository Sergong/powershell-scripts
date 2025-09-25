<#
.SYNOPSIS
Test script for ONTAP Toolkit 9.17 individual parameters approach

.DESCRIPTION
This script tests the individual parameter approach for Add-NcCifsShare in ONTAP Toolkit 9.17,
specifically testing -HomeDirectory $True and other individual property parameters.

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
    
    # Get toolkit version
    $ModuleInfo = Get-Module NetApp.ONTAP
    Write-Host "NetApp PowerShell Toolkit Version: $($ModuleInfo.Version)" -ForegroundColor Cyan
    
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

    # Check available parameters for Add-NcCifsShare
    Write-Host "`nChecking Add-NcCifsShare available parameters..." -ForegroundColor Yellow
    $CmdletInfo = Get-Command Add-NcCifsShare
    $AvailableParams = $CmdletInfo.Parameters.Keys | Sort-Object
    
    Write-Host "Available parameters:" -ForegroundColor White
    $AvailableParams | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
    
    # Check for individual property parameters
    $IndividualParams = @('HomeDirectory', 'Browsable', 'Oplocks', 'ChangeNotify', 'ShowSnapshot', 'AttributeCache', 'ContinuouslyAvailable', 'AccessBasedEnumeration', 'BranchCache', 'EncryptData')
    $SupportedIndividualParams = @()
    
    Write-Host "`nChecking for individual property parameters:" -ForegroundColor Yellow
    foreach ($Param in $IndividualParams) {
        if ($AvailableParams -contains $Param) {
            Write-Host "  ✅ $Param - Supported" -ForegroundColor Green
            $SupportedIndividualParams += $Param
        } else {
            Write-Host "  ❌ $Param - Not supported" -ForegroundColor Red
        }
    }
    
    # Check for ShareProperties parameter
    if ($AvailableParams -contains 'ShareProperties') {
        Write-Host "  ✅ ShareProperties - Supported (array method)" -ForegroundColor Green
    } else {
        Write-Host "  ❌ ShareProperties - Not supported" -ForegroundColor Red
    }

    # Test 1: Create a basic share with individual parameters
    Write-Host "`nTest 1: Creating share with individual parameters..." -ForegroundColor Yellow
    
    $TestShareName = "TestShare_Individual_Params"
    $TestSharePath = "/vol0"
    
    # Remove existing test share if it exists
    $ExistingShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShareName -ErrorAction SilentlyContinue
    if ($ExistingShare) {
        Write-Host "[INFO] Test share already exists, removing it first..." -ForegroundColor Yellow
        Remove-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShareName -Confirm:$false
    }
    
    # Build parameters with individual properties (if supported)
    $ShareParams = @{
        Controller = $TargetController
        VserverContext = $TargetSVM
        Name = $TestShareName
        Path = $TestSharePath
    }
    
    # Add individual property parameters if they're supported
    if ($SupportedIndividualParams -contains 'HomeDirectory') {
        $ShareParams.HomeDirectory = $false  # Test with false first
        Write-Host "  Setting HomeDirectory = false" -ForegroundColor White
    }
    
    if ($SupportedIndividualParams -contains 'Browsable') {
        $ShareParams.Browsable = $true
        Write-Host "  Setting Browsable = true" -ForegroundColor White
    }
    
    if ($SupportedIndividualParams -contains 'Oplocks') {
        $ShareParams.Oplocks = $true
        Write-Host "  Setting Oplocks = true" -ForegroundColor White
    }
    
    try {
        Add-NcCifsShare @ShareParams
        Write-Host "[OK] Share created successfully with individual parameters!" -ForegroundColor Green
        
        # Verify the share
        $CreatedShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShareName
        if ($CreatedShare) {
            Write-Host "Share Properties: $($CreatedShare.ShareProperties -join ', ')" -ForegroundColor White
        }
        
    } catch {
        Write-Host "[NOK] Failed with individual parameters: $($_.Exception.Message)" -ForegroundColor Red
        
        # Fallback: Try with ShareProperties array if individual parameters failed
        if ($AvailableParams -contains 'ShareProperties') {
            Write-Host "Trying fallback with ShareProperties array..." -ForegroundColor Yellow
            
            $ShareParamsFallback = @{
                Controller = $TargetController
                VserverContext = $TargetSVM
                Name = $TestShareName
                Path = $TestSharePath
                ShareProperties = @('browsable', 'oplocks')
            }
            
            try {
                Add-NcCifsShare @ShareParamsFallback
                Write-Host "[OK] Share created successfully with ShareProperties array!" -ForegroundColor Green
                
                $CreatedShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShareName
                if ($CreatedShare) {
                    Write-Host "Share Properties: $($CreatedShare.ShareProperties -join ', ')" -ForegroundColor White
                }
            } catch {
                Write-Host "[NOK] Both individual parameters and ShareProperties array failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    
    # Test 2: Create dynamic share with HomeDirectory
    Write-Host "`nTest 2: Creating dynamic share with HomeDirectory..." -ForegroundColor Yellow
    
    $DynamicShareName = "home_%w"
    $DynamicSharePath = "/home/%w"
    
    # Remove existing dynamic share if it exists
    $ExistingDynamicShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $DynamicShareName -ErrorAction SilentlyContinue
    if ($ExistingDynamicShare) {
        Remove-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $DynamicShareName -Confirm:$false
    }
    
    # Build dynamic share parameters
    $DynamicShareParams = @{
        Controller = $TargetController
        VserverContext = $TargetSVM
        Name = $DynamicShareName
        Path = $DynamicSharePath
    }
    
    # Set HomeDirectory if supported
    if ($SupportedIndividualParams -contains 'HomeDirectory') {
        $DynamicShareParams.HomeDirectory = $true
        Write-Host "  Setting HomeDirectory = true for dynamic share" -ForegroundColor White
    }
    
    try {
        Add-NcCifsShare @DynamicShareParams
        Write-Host "[OK] Dynamic share created successfully!" -ForegroundColor Green
        
        $CreatedDynamicShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $DynamicShareName
        if ($CreatedDynamicShare) {
            Write-Host "Dynamic Share Properties: $($CreatedDynamicShare.ShareProperties -join ', ')" -ForegroundColor White
        }
        
    } catch {
        Write-Host "[NOK] Dynamic share creation failed: $($_.Exception.Message)" -ForegroundColor Red
        
        # Fallback for dynamic share
        if ($AvailableParams -contains 'ShareProperties') {
            Write-Host "Trying dynamic share with ShareProperties array..." -ForegroundColor Yellow
            
            $DynamicShareParamsFallback = @{
                Controller = $TargetController
                VserverContext = $TargetSVM
                Name = $DynamicShareName
                Path = $DynamicSharePath
                ShareProperties = @('homedirectory')
            }
            
            try {
                Add-NcCifsShare @DynamicShareParamsFallback
                Write-Host "[OK] Dynamic share created with ShareProperties array!" -ForegroundColor Green
                
                $CreatedDynamicShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $DynamicShareName
                if ($CreatedDynamicShare) {
                    Write-Host "Dynamic Share Properties: $($CreatedDynamicShare.ShareProperties -join ', ')" -ForegroundColor White
                }
            } catch {
                Write-Host "[NOK] Dynamic share creation failed with both methods: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    
    Write-Host "`n=== Test Results Summary ===" -ForegroundColor Cyan
    Write-Host "ONTAP Toolkit Version: $($ModuleInfo.Version)" -ForegroundColor White
    Write-Host "Supported Individual Parameters: $($SupportedIndividualParams.Count)" -ForegroundColor White
    if ($SupportedIndividualParams.Count -gt 0) {
        Write-Host "  ✅ Individual parameters approach is supported" -ForegroundColor Green
        Write-Host "  Parameters: $($SupportedIndividualParams -join ', ')" -ForegroundColor Gray
    } else {
        Write-Host "  ❌ Individual parameters approach is NOT supported" -ForegroundColor Red
        Write-Host "  Use ShareProperties array instead" -ForegroundColor Yellow
    }
    
    # Cleanup
    Write-Host "`nCleaning up test shares..." -ForegroundColor Yellow
    try {
        Remove-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShareName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $DynamicShareName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "[OK] Test shares cleaned up" -ForegroundColor Green
    } catch {
        Write-Host "[WARNING] Could not clean up all test shares" -ForegroundColor Yellow
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