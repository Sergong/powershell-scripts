<#
.SYNOPSIS
    Update an existing CNAME record to point to a new A record and force AD-integrated DNS replication.

.DESCRIPTION
    This script modifies an existing CNAME (alias) in a specified DNS zone to reference a different A record,
    then forces immediate replication of the DNS zone across all domain controllers so clients see the change as soon as possible.

.PARAMETER ZoneName
    The DNS zone where the CNAME resides (e.g., "contoso.com").

.PARAMETER CName
    The alias name of the existing CNAME record (e.g., "app").

.PARAMETER NewTarget
    The new FQDN of the A record to which the CNAME should point (e.g., "webserver.contoso.com").

.PARAMETER DnsServer
    (Optional) The DNS server to perform the change on. Defaults to the local server.

.PARAMETER ForceReplication
    Switch parameter. If specified, triggers AD replication after updating the CNAME.

.EXAMPLE
    .\Update-CnameAndReplicate.ps1 -ZoneName "contoso.com" -CName "app" -NewTarget "web2.contoso.com"

.EXAMPLE
    .\Update-CnameAndReplicate.ps1 -ZoneName "contoso.com" -CName "app" -NewTarget "web2.contoso.com" -ForceReplication
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ZoneName,

    [Parameter(Mandatory=$true)]
    [string]$CName,

    [Parameter(Mandatory=$true)]
    [string]$NewTarget,

    [Parameter(Mandatory=$false)]
    [string]$DnsServer = $env:COMPUTERNAME,

    [Parameter(Mandatory=$false)]
    [switch]$ForceReplication
)

# Import DNS Server module
Import-Module DnsServer -ErrorAction Stop

# Compose record specifics
$RecordName = "$CName"
$Zone = $ZoneName
$Server = $DnsServer

Write-Host "Updating CNAME record '$RecordName.$Zone' on DNS server '$Server' to point to '$NewTarget'..." -ForegroundColor Cyan

try {
    # Retrieve existing CNAME
    $existing = Get-DnsServerResourceRecord -ZoneName $Zone -Name $RecordName -RRType CNAME -ComputerName $Server -ErrorAction Stop
    if (-not $existing) {
        throw "CNAME record '$RecordName' not found in zone '$Zone'."
    }

    # Remove old CNAME record
    Remove-DnsServerResourceRecord -ZoneName $Zone -RRType CNAME -Name $RecordName -RecordData $existing.RecordData.HostNameAlias -ComputerName $Server -Force -ErrorAction Stop
    Write-Host "[OK] Removed existing CNAME alias pointing to '$($existing.RecordData.HostNameAlias)'." -ForegroundColor Green

    # Add new CNAME record pointing to new target
    Add-DnsServerResourceRecordCName -ZoneName $Zone -Name $RecordName -HostNameAlias $NewTarget -TimeToLive 00:05:00 -ComputerName $Server -ErrorAction Stop
    Write-Host "[OK] Created new CNAME alias '$RecordName.$Zone' → '$NewTarget'." -ForegroundColor Green

} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}

if ($ForceReplication) {
    Write-Host "`nForcing AD-integrated DNS zone replication..." -ForegroundColor Cyan
    try {
        # Import Active Directory module
        Import-Module ActiveDirectory -ErrorAction Stop

        # Retrieve all DCs hosting this DNS zone directory partition
        $zonePartition = (Get-DnsServerZone -Name $Zone -ComputerName $Server).DirectoryPartition
        $dcList = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName

        foreach ($dc in $dcList) {
            Write-Host "→ Syncing from this DC to others: $dc" -NoNewline
            # Run repadmin syncall for the zone's partition
            $arguments = @("/syncall", $dc, "/AeDq", $zonePartition)
            & repadmin @arguments | Out-Host
        }

        Write-Host "[OK] AD-integrated DNS zone replication initiated." -ForegroundColor Green

    } catch {
        Write-Host "WARNING: Failed to trigger AD replication: $_" -ForegroundColor Yellow
    }
}

Write-Host "`nOperation completed. Verify DNS records with:" -ForegroundColor Cyan
Write-Host "  Resolve-DnsName -Name $RecordName.$Zone -Server $Server" -ForegroundColor White
