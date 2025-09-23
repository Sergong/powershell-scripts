<#
.SYNOPSIS
    Debug script to help troubleshoot LIF discovery issues

.DESCRIPTION
    This script connects to an ONTAP cluster and lists all LIFs on a specified SVM
    to help debug LIF discovery issues in the main migration script.

.PARAMETER Cluster
    ONTAP cluster management IP or FQDN

.PARAMETER SVM
    SVM name to examine

.PARAMETER Credential
    PSCredential object for ONTAP authentication

.EXAMPLE
    .\Debug-LIFDiscovery.ps1 -Cluster "cluster.domain.com" -SVM "target_svm"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Cluster,
    
    [Parameter(Mandatory=$true)]
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

    # Get all LIFs on the SVM
    Write-Host "`nRetrieving all LIFs on SVM: $SVM" -ForegroundColor Yellow
    $AllLIFs = Get-NcNetInterface -Controller $Controller -VserverContext $SVM
    
    if (!$AllLIFs -or $AllLIFs.Count -eq 0) {
        Write-Host "[ERROR] No LIFs found on SVM: $SVM" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "[OK] Found $($AllLIFs.Count) total LIFs on SVM: $SVM" -ForegroundColor Green
    Write-Host ""
    
    # Display all LIFs with detailed information
    Write-Host "=== ALL LIFs ON SVM ===" -ForegroundColor Cyan
    foreach ($LIF in $AllLIFs | Sort-Object InterfaceName) {
        $ProtocolsStr = if ($LIF.DataProtocols) { $LIF.DataProtocols -join ',' } else { "none" }
        Write-Host "LIF: $($LIF.InterfaceName)" -ForegroundColor White
        Write-Host "  Address: $($LIF.Address)" -ForegroundColor Gray
        Write-Host "  Protocols: $ProtocolsStr" -ForegroundColor Gray
        Write-Host "  Role: $($LIF.Role)" -ForegroundColor Gray
        Write-Host "  Admin Status: $($LIF.AdministrativeStatus)" -ForegroundColor Gray
        Write-Host "  Operational Status: $($LIF.OperationalStatus)" -ForegroundColor Gray
        Write-Host "  Current Node: $($LIF.CurrentNode)" -ForegroundColor Gray
        Write-Host "  Current Port: $($LIF.CurrentPort)" -ForegroundColor Gray
        Write-Host ""
    }
    
    # Filter for CIFS/SMB LIFs
    Write-Host "=== CIFS/SMB DATA LIFs ===" -ForegroundColor Cyan
    $CifsLIFs = $AllLIFs | Where-Object {
        # Check for CIFS/SMB protocols (handle different ONTAP versions)
        $HasCifsProtocol = ($_.DataProtocols -contains "cifs") -or 
                          ($_.DataProtocols -contains "smb") -or 
                          ($_.DataProtocols -contains "data_cifs") -or
                          ($_.DataProtocols -join ',' -match 'cifs')
        
        # Check for data role (handle different ONTAP versions)
        $HasDataRole = ($_.Role -eq "data") -or 
                      ($_.Role -contains "data") -or 
                      ($_.Role -contains "data_cifs") -or
                      ($_.Role -match 'data')
        
        $HasCifsProtocol -and $HasDataRole
    }
    
    if ($CifsLIFs) {
        Write-Host "[OK] Found $($CifsLIFs.Count) CIFS/SMB data LIFs:" -ForegroundColor Green
        foreach ($LIF in $CifsLIFs | Sort-Object InterfaceName) {
            $StatusColor = if ($LIF.AdministrativeStatus -eq "up") { "Green" } else { "Yellow" }
            Write-Host "  - $($LIF.InterfaceName): $($LIF.Address) (Status: $($LIF.AdministrativeStatus))" -ForegroundColor $StatusColor
        }
    } else {
        Write-Host "[ERROR] No CIFS/SMB data LIFs found!" -ForegroundColor Red
        
        # Show what we did find
        Write-Host "`n=== DETAILED ANALYSIS ===" -ForegroundColor Yellow
        
        # Check for any LIFs with CIFS-like protocols
        $CifsLikeProtocols = $AllLIFs | Where-Object { 
            ($_.DataProtocols -join ',' -match 'cifs') -or 
            ($_.DataProtocols -contains "smb") -or 
            ($_.DataProtocols -contains "data_cifs")
        }
        if ($CifsLikeProtocols) {
            Write-Host "LIFs with CIFS-related protocols:" -ForegroundColor Yellow
            foreach ($LIF in $CifsLikeProtocols) {
                $ProtocolsStr = if ($LIF.DataProtocols) { $LIF.DataProtocols -join ',' } else { "none" }
                $RoleStr = if ($LIF.Role) { $LIF.Role } else { "none" }
                Write-Host "  - $($LIF.InterfaceName):" -ForegroundColor Yellow
                Write-Host "    Protocols: $ProtocolsStr" -ForegroundColor Gray
                Write-Host "    Role: $RoleStr" -ForegroundColor Gray
            }
        }
        
        # Check for any LIFs with data-like roles
        $DataLikeRoles = $AllLIFs | Where-Object { 
            ($_.Role -match 'data') -or 
            ($_.Role -contains "data") -or 
            ($_.Role -contains "data_cifs")
        }
        if ($DataLikeRoles) {
            Write-Host "`nLIFs with data-related roles:" -ForegroundColor Yellow
            foreach ($LIF in $DataLikeRoles) {
                $ProtocolsStr = if ($LIF.DataProtocols) { $LIF.DataProtocols -join ',' } else { "none" }
                $RoleStr = if ($LIF.Role) { $LIF.Role } else { "none" }
                Write-Host "  - $($LIF.InterfaceName):" -ForegroundColor Yellow
                Write-Host "    Protocols: $ProtocolsStr" -ForegroundColor Gray
                Write-Host "    Role: $RoleStr" -ForegroundColor Gray
            }
        }
    }
    
    # Show recommendations
    Write-Host "`n=== RECOMMENDATIONS ===" -ForegroundColor Cyan
    if ($CifsLIFs) {
        $UpCifsLIFs = $CifsLIFs | Where-Object { $_.AdministrativeStatus -eq "up" }
        $DownCifsLIFs = $CifsLIFs | Where-Object { $_.AdministrativeStatus -ne "up" }
        
        if ($UpCifsLIFs) {
            Write-Host "✅ $($UpCifsLIFs.Count) CIFS LIFs are administratively UP" -ForegroundColor Green
        }
        if ($DownCifsLIFs) {
            Write-Host "⚠️  $($DownCifsLIFs.Count) CIFS LIFs are administratively DOWN" -ForegroundColor Yellow
            Write-Host "   This is normal for target LIFs during migration setup" -ForegroundColor Yellow
        }
        Write-Host "✅ The migration script should discover these LIFs successfully" -ForegroundColor Green
    } else {
        Write-Host "❌ No CIFS/SMB data LIFs found. Please check:" -ForegroundColor Red
        Write-Host "   1. SVM has CIFS protocol enabled" -ForegroundColor Red
        Write-Host "   2. LIFs are created with 'cifs' or 'smb' in data protocols" -ForegroundColor Red
        Write-Host "   3. LIFs have role 'data'" -ForegroundColor Red
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