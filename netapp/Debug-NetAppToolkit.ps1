<#
.SYNOPSIS
Debug script to check NetApp PowerShell Toolkit version and supported parameters

.DESCRIPTION
This script helps diagnose issues with the NetApp PowerShell Toolkit by showing:
- Toolkit version
- Available cmdlets
- Parameters supported by Add-NcCifsShare
- Sample share creation without ShareProperties
#>

try {
    # Import NetApp PowerShell Toolkit
    Import-Module NetApp.ONTAP -ErrorAction Stop
    Write-Host "[OK] NetApp PowerShell Toolkit loaded successfully" -ForegroundColor Green
    
    # Get toolkit version
    $ModuleInfo = Get-Module NetApp.ONTAP
    Write-Host "NetApp PowerShell Toolkit Version: $($ModuleInfo.Version)" -ForegroundColor Cyan
    Write-Host "NetApp PowerShell Toolkit Path: $($ModuleInfo.ModuleBase)" -ForegroundColor Cyan
    
    # Check Add-NcCifsShare parameters
    Write-Host "`nAdd-NcCifsShare Parameters:" -ForegroundColor Yellow
    $CmdletInfo = Get-Command Add-NcCifsShare -ErrorAction SilentlyContinue
    
    if ($CmdletInfo) {
        $CmdletInfo.Parameters.Keys | Sort-Object | ForEach-Object {
            $ParamType = $CmdletInfo.Parameters[$_].ParameterType.Name
            Write-Host "  - $($_): $ParamType" -ForegroundColor White
        }
        
        # Check if ShareProperties parameter exists
        if ($CmdletInfo.Parameters.ContainsKey('ShareProperties')) {
            Write-Host "`n[OK] ShareProperties parameter is supported" -ForegroundColor Green
        } else {
            Write-Host "`n[NOK] ShareProperties parameter is NOT supported in this version" -ForegroundColor Red
            Write-Host "This toolkit version uses REST API calls that don't support ShareProperties" -ForegroundColor Yellow
            Write-Host "ShareProperties must be set via ZAPI calls instead" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[NOK] Add-NcCifsShare cmdlet not found!" -ForegroundColor Red
    }
    
    # Check Set-NcCifsShare parameters (for property modification)
    Write-Host "`nSet-NcCifsShare Parameters (if available):" -ForegroundColor Yellow
    $SetCmdletInfo = Get-Command Set-NcCifsShare -ErrorAction SilentlyContinue
    
    if ($SetCmdletInfo) {
        $SetCmdletInfo.Parameters.Keys | Sort-Object | ForEach-Object {
            $ParamType = $SetCmdletInfo.Parameters[$_].ParameterType.Name
            Write-Host "  - $($_): $ParamType" -ForegroundColor White
        }
    } else {
        Write-Host "Set-NcCifsShare cmdlet not available" -ForegroundColor Gray
    }
    
    # Check ZAPI support
    Write-Host "`nZAPI Support:" -ForegroundColor Yellow
    $ZapiCmdlet = Get-Command Invoke-NcSystemApi -ErrorAction SilentlyContinue
    if ($ZapiCmdlet) {
        Write-Host "[OK] Invoke-NcSystemApi available for ZAPI calls" -ForegroundColor Green
    } else {
        Write-Host "[NOK] Invoke-NcSystemApi not available" -ForegroundColor Red
    }
    
    Write-Host "`nSolution:" -ForegroundColor Cyan
    Write-Host "- Create shares without ShareProperties parameter using Add-NcCifsShare" -ForegroundColor White
    Write-Host "- Set ShareProperties after creation using ZAPI (Invoke-NcSystemApi)" -ForegroundColor White
    Write-Host "- This is the approach the fixed script now uses" -ForegroundColor White
    
} catch {
    Write-Error "Failed to load NetApp PowerShell Toolkit: $($_.Exception.Message)"
    Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
    Write-Host "1. Install NetApp PowerShell Toolkit: Install-Module NetApp.ONTAP" -ForegroundColor White
    Write-Host "2. Check if you have multiple versions installed: Get-Module NetApp.ONTAP -ListAvailable" -ForegroundColor White
    Write-Host "3. Update to latest version: Update-Module NetApp.ONTAP" -ForegroundColor White
}