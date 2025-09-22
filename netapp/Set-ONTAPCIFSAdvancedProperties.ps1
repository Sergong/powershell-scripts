<#
.SYNOPSIS
    Configures advanced CIFS share properties that are not supported via REST API in NetApp PowerShell Toolkit.

.DESCRIPTION
    This script reads the exported CIFS configuration and applies advanced properties like
    ShareProperties, SymlinkProperties, and VscanProfile using ONTAP CLI commands via SSH.
    Use this after running Import-ONTAPCIFSConfiguration.ps1 to complete the configuration.

.PARAMETER ImportPath
    Path to the exported configuration directory

.PARAMETER TargetCluster
    Target ONTAP cluster management IP or FQDN

.PARAMETER TargetSVM
    Target SVM name where shares were imported

.PARAMETER Credential
    PSCredential object for target ONTAP authentication

.PARAMETER WhatIf
    Show what would be configured without making changes

.EXAMPLE
    .\Set-ONTAPCIFSAdvancedProperties.ps1 -ImportPath "C:\Export\svm_Export_2024-01-01_12-00-00" -TargetCluster "cluster.domain.com" -TargetSVM "target_svm"

.NOTES
    This script uses SSH to connect to ONTAP CLI since these properties are not available via REST API.
    Requires Posh-SSH module: Install-Module Posh-SSH -Force
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
    [switch]$WhatIf
)

# Check for Posh-SSH module
try {
    Import-Module Posh-SSH -ErrorAction Stop
    Write-Host "[OK] Posh-SSH module loaded successfully" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Posh-SSH module is required but not found." -ForegroundColor Red
    Write-Host "Install it with: Install-Module Posh-SSH -Force" -ForegroundColor Yellow
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
$LogFile = Join-Path $ImportPath "AdvancedProperties-Log-$(Get-Date -Format 'yyyy-MM-dd-HH-mm-ss').txt"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $LogEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry
}

Write-Log "=== ONTAP CIFS Advanced Properties Configuration Started ==="
Write-Log "Import Path: $ImportPath"
Write-Log "Target Cluster: $TargetCluster"
Write-Log "Target SVM: $TargetSVM"

try {
    # Load shares configuration
    $SharesFile = Join-Path $ImportPath "CIFS-Shares.json"
    if (!(Test-Path $SharesFile)) {
        throw "CIFS shares file not found: $SharesFile"
    }
    
    $ImportedShares = Get-Content -Path $SharesFile | ConvertFrom-Json
    Write-Log "[OK] Loaded $($ImportedShares.Count) CIFS shares from export"
    
    # Filter shares that have advanced properties to configure
    $SharesWithAdvancedProps = $ImportedShares | Where-Object {
        ($_.ShareProperties -and $_.ShareProperties.Count -gt 0) -or
        ($_.SymlinkProperties -and $_.SymlinkProperties.Count -gt 0) -or
        ($_.VscanProfile -and $_.VscanProfile.Count -gt 0)
    }
    
    if ($SharesWithAdvancedProps.Count -eq 0) {
        Write-Log "[INFO] No shares found with advanced properties to configure" "INFO"
        Write-Log "=== Configuration Complete - No Advanced Properties Required ===" "SUCCESS"
        return
    }
    
    Write-Log "[OK] Found $($SharesWithAdvancedProps.Count) shares with advanced properties to configure"
    
    # Connect via SSH to ONTAP cluster
    Write-Log "Connecting to ONTAP cluster via SSH: $TargetCluster"
    
    if ($WhatIf) {
        Write-Log "[WHATIF] Would connect via SSH to configure advanced properties"
        
        foreach ($Share in $SharesWithAdvancedProps) {
            $ShareName = $Share.ShareName
            Write-Log "[WHATIF] Would configure share: $ShareName"
            
            if ($Share.ShareProperties) {
                Write-Log "[WHATIF] Would set ShareProperties: $($Share.ShareProperties -join ', ')"
            }
            if ($Share.SymlinkProperties) {
                Write-Log "[WHATIF] Would set SymlinkProperties: $($Share.SymlinkProperties -join ', ')"
            }
            if ($Share.VscanProfile) {
                Write-Log "[WHATIF] Would set VscanProfile: $($Share.VscanProfile -join ', ')"
            }
        }
        
        Write-Log "=== WHATIF Mode - No Changes Made ===" "SUCCESS"
        return
    }
    
    $SSHSession = New-SSHSession -ComputerName $TargetCluster -Credential $Credential -ErrorAction Stop
    Write-Log "[OK] SSH session established successfully"
    
    $PropertiesConfigured = 0
    
    foreach ($Share in $SharesWithAdvancedProps) {
        $ShareName = $Share.ShareName
        Write-Log "Configuring advanced properties for share: $ShareName"
        
        try {
            # Configure ShareProperties
            if ($Share.ShareProperties -and $Share.ShareProperties.Count -gt 0) {
                $SharePropsString = $Share.ShareProperties -join ','
                $Command = "vserver cifs share properties add -vserver $TargetSVM -share-name `"$ShareName`" -share-properties $SharePropsString"
                Write-Log "[INFO] Executing: $Command"
                
                $Result = Invoke-SSHCommand -SSHSession $SSHSession -Command $Command
                if ($Result.ExitStatus -eq 0) {
                    Write-Log "[OK] Successfully configured ShareProperties for $ShareName"
                    $PropertiesConfigured++
                } else {
                    Write-Log "[NOK] Failed to configure ShareProperties for ${ShareName}: $($Result.Output)" "ERROR"
                }
            }
            
            # Configure SymlinkProperties  
            if ($Share.SymlinkProperties -and $Share.SymlinkProperties.Count -gt 0) {
                $SymlinkPropsString = $Share.SymlinkProperties -join ','
                $Command = "vserver cifs share properties add -vserver $TargetSVM -share-name `"$ShareName`" -symlink-properties $SymlinkPropsString"
                Write-Log "[INFO] Executing: $Command"
                
                $Result = Invoke-SSHCommand -SSHSession $SSHSession -Command $Command
                if ($Result.ExitStatus -eq 0) {
                    Write-Log "[OK] Successfully configured SymlinkProperties for $ShareName"
                    $PropertiesConfigured++
                } else {
                    Write-Log "[NOK] Failed to configure SymlinkProperties for ${ShareName}: $($Result.Output)" "ERROR"
                }
            }
            
            # Configure VscanProfile
            if ($Share.VscanProfile -and $Share.VscanProfile.Count -gt 0) {
                $VscanProfileString = $Share.VscanProfile -join ','
                $Command = "vserver cifs share modify -vserver $TargetSVM -share-name `"$ShareName`" -vscan-fileop-profile $VscanProfileString"
                Write-Log "[INFO] Executing: $Command"
                
                $Result = Invoke-SSHCommand -SSHSession $SSHSession -Command $Command
                if ($Result.ExitStatus -eq 0) {
                    Write-Log "[OK] Successfully configured VscanProfile for $ShareName"
                    $PropertiesConfigured++
                } else {
                    Write-Log "[NOK] Failed to configure VscanProfile for ${ShareName}: $($Result.Output)" "ERROR"
                }
            }
            
        } catch {
            Write-Log "[NOK] Failed to configure advanced properties for share ${ShareName}: $($_.Exception.Message)" "ERROR"
        }
    }
    
    Write-Log "=== CIFS Advanced Properties Configuration Completed ===" "SUCCESS"
    Write-Log "Properties Configured: $PropertiesConfigured"
    
} catch {
    Write-Log "Configuration failed with error: $($_.Exception.Message)" "ERROR"
    throw
} finally {
    if ($SSHSession) {
        try {
            Remove-SSHSession -SSHSession $SSHSession
            Write-Log "[OK] SSH session closed"
        } catch {
            Write-Log "[NOK] Warning: Could not properly close SSH session: $($_.Exception.Message)" "WARNING"
        }
    }
}

# Display summary
Write-Host "`n=== Advanced Properties Configuration Summary ===" -ForegroundColor Cyan
Write-Host "Target: $TargetCluster -> $TargetSVM" -ForegroundColor White
Write-Host "Shares with Advanced Properties: $($SharesWithAdvancedProps.Count)" -ForegroundColor Green
Write-Host "Properties Configured: $PropertiesConfigured" -ForegroundColor Green
Write-Host "Configuration Log: $LogFile" -ForegroundColor Yellow

if ($SharesWithAdvancedProps.Count -gt $PropertiesConfigured) {
    Write-Host "`nWARNING: Some properties may not have been configured successfully." -ForegroundColor Yellow
    Write-Host "Check the log file for details: $LogFile" -ForegroundColor Yellow
}