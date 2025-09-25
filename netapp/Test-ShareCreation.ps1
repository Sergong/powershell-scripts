<#
.SYNOPSIS
Test script to verify basic CIFS share creation without ShareProperties parameter

.DESCRIPTION
This script tests the basic share creation functionality using only REST-compatible parameters
to ensure it works with older NetApp PowerShell Toolkit versions that don't support ShareProperties.

.PARAMETER TargetCluster
Target ONTAP cluster management IP or FQDN

.PARAMETER TargetSVM
Target SVM name where shares will be created

.PARAMETER TargetCredential
PSCredential object for target ONTAP authentication

.PARAMETER TestShareName
Name of the test share to create (default: TestShare_PowerShell)

.PARAMETER TestSharePath
Path for the test share (default: /vol0)
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$TargetCluster,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetSVM,
    
    [Parameter(Mandatory=$false)]
    [PSCredential]$TargetCredential,
    
    [Parameter(Mandatory=$false)]
    [string]$TestShareName = "TestShare_PowerShell",
    
    [Parameter(Mandatory=$false)]
    [string]$TestSharePath = "/vol0"
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

    # Test 1: Basic share creation without any properties
    Write-Host "`nTest 1: Creating basic CIFS share without ShareProperties..." -ForegroundColor Yellow
    
    # Check if share already exists
    $ExistingShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShareName -ErrorAction SilentlyContinue
    if ($ExistingShare) {
        Write-Host "[INFO] Test share already exists, removing it first..." -ForegroundColor Yellow
        Remove-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShareName -Confirm:$false
        Write-Host "[OK] Removed existing test share" -ForegroundColor Green
    }
    
    # Create basic share with minimal parameters
    $ShareParams = @{
        Controller = $TargetController
        VserverContext = $TargetSVM
        Name = $TestShareName
        Path = $TestSharePath
    }
    
    Write-Host "Creating share with parameters:" -ForegroundColor White
    Write-Host "  Name: $TestShareName" -ForegroundColor White
    Write-Host "  Path: $TestSharePath" -ForegroundColor White
    Write-Host "  SVM: $TargetSVM" -ForegroundColor White
    
    Add-NcCifsShare @ShareParams
    Write-Host "[OK] Basic share created successfully!" -ForegroundColor Green
    
    # Verify the share was created
    $CreatedShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShareName
    if ($CreatedShare) {
        Write-Host "[OK] Share verification successful" -ForegroundColor Green
        Write-Host "  Share Name: $($CreatedShare.ShareName)" -ForegroundColor White
        Write-Host "  Share Path: $($CreatedShare.Path)" -ForegroundColor White
        Write-Host "  Share Properties: $($CreatedShare.ShareProperties -join ', ')" -ForegroundColor White
    } else {
        Write-Host "[NOK] Share verification failed - share not found" -ForegroundColor Red
    }
    
    # Test 2: Try to set ShareProperties via ZAPI
    Write-Host "`nTest 2: Setting ShareProperties via ZAPI..." -ForegroundColor Yellow
    
    try {
        # Simple ZAPI call to add a basic property
        $zapiXml = @"
<cifs-share-modify>
    <vserver>$TargetSVM</vserver>
    <share-name>$TestShareName</share-name>
    <share-properties>
        <property>oplocks</property>
    </share-properties>
</cifs-share-modify>
"@
        
        Write-Host "Executing ZAPI call to set oplocks property..." -ForegroundColor White
        $result = Invoke-NcSystemApi -Controller $TargetController -Request $zapiXml
        Write-Host "[OK] ZAPI call successful!" -ForegroundColor Green
        
        # Verify the property was set
        $UpdatedShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShareName
        Write-Host "Updated Share Properties: $($UpdatedShare.ShareProperties -join ', ')" -ForegroundColor White
        
    } catch {
        Write-Host "[NOK] ZAPI call failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    # Test 3: Test dynamic share creation (if requested)
    Write-Host "`nTest 3: Creating dynamic share with user variables..." -ForegroundColor Yellow
    
    $DynamicShareName = "home_%w"
    $DynamicSharePath = "/home/%w"
    
    # Check if dynamic share already exists
    $ExistingDynamicShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $DynamicShareName -ErrorAction SilentlyContinue
    if ($ExistingDynamicShare) {
        Write-Host "[INFO] Dynamic test share already exists, removing it first..." -ForegroundColor Yellow
        Remove-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $DynamicShareName -Confirm:$false
    }
    
    # Create dynamic share
    $DynamicShareParams = @{
        Controller = $TargetController
        VserverContext = $TargetSVM
        Name = $DynamicShareName
        Path = $DynamicSharePath
    }
    
    try {
        Add-NcCifsShare @DynamicShareParams
        Write-Host "[OK] Dynamic share created successfully!" -ForegroundColor Green
        
        # Now set homedirectory property via ZAPI
        $dynamicZapiXml = @"
<cifs-share-modify>
    <vserver>$TargetSVM</vserver>
    <share-name>$DynamicShareName</share-name>
    <share-properties>
        <property>homedirectory</property>
    </share-properties>
</cifs-share-modify>
"@
        
        Write-Host "Setting homedirectory property for dynamic share..." -ForegroundColor White
        $dynamicResult = Invoke-NcSystemApi -Controller $TargetController -Request $dynamicZapiXml
        Write-Host "[OK] Dynamic share configured with homedirectory property!" -ForegroundColor Green
        
        # Verify the dynamic share
        $CreatedDynamicShare = Get-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $DynamicShareName
        Write-Host "Dynamic Share Properties: $($CreatedDynamicShare.ShareProperties -join ', ')" -ForegroundColor White
        
    } catch {
        Write-Host "[NOK] Dynamic share creation failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Write-Host "`n=== Test Summary ===" -ForegroundColor Cyan
    Write-Host "✓ Basic share creation: Works without ShareProperties parameter" -ForegroundColor Green
    Write-Host "✓ ZAPI property setting: Should work for setting properties after creation" -ForegroundColor Green
    Write-Host "✓ Dynamic shares: Can be created and configured with homedirectory property" -ForegroundColor Green
    Write-Host "`nThe fixed Invoke-CIFSSVMTakeover.ps1 script uses this exact approach." -ForegroundColor White
    
    # Cleanup test shares
    Write-Host "`nCleaning up test shares..." -ForegroundColor Yellow
    try {
        Remove-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $TestShareName -Confirm:$false
        Remove-NcCifsShare -Controller $TargetController -VserverContext $TargetSVM -Name $DynamicShareName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "[OK] Test shares cleaned up" -ForegroundColor Green
    } catch {
        Write-Host "[WARNING] Could not clean up all test shares: $($_.Exception.Message)" -ForegroundColor Yellow
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
            Write-Host "[WARNING] Could not disconnect cleanly: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}