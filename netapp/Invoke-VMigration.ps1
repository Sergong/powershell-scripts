<#
.SYNOPSIS
    Migrates VMs from source vSphere 7 environment to target vSphere 8 environment with NetApp ONTAP backing.
    Includes automated guest OS IP configuration using Invoke-VMScript.

.DESCRIPTION
    This script automates the migration of VMs from a source vSphere environment to a target vSphere environment.
    Both environments are backed by NetApp ONTAP clusters with NFS datastores. The script handles the complete
    migration workflow including VM discovery, power operations, SnapMirror operations, datastore mounting,
    VM registration, network reconfiguration, automated guest OS IP configuration, and cleanup operations.
    
    The script automatically configures IP settings within Windows and Linux guest operating systems using
    Invoke-VMScript, eliminating the need for manual post-migration network configuration.

.PARAMETER CSVPath
    Path to the CSV file containing VM migration information.
    Required columns: VMName, VMDatastore, TargetVLAN, TargetIP, TargetSNMask, TargetGW, TargetDNS1, TargetDNS2

.PARAMETER SourcevCenter
    FQDN or IP address of the source vCenter server.

.PARAMETER TargetvCenter
    FQDN or IP address of the target vCenter server.

.PARAMETER TargetONTAPCluster
    FQDN or IP address of the target NetApp ONTAP cluster.

.PARAMETER TargetNFSSVM
    Name of the target NFS SVM on the ONTAP cluster.

.PARAMETER LogPath
    Path where log files will be written. Default is current directory with timestamp.

.PARAMETER BackupTier
    Name of the backup tier tag to apply to migrated VMs. Default is "Tier3".

.PARAMETER GuestCredentials
    PSCredential object for guest OS operations. If not provided, will be prompted.

.PARAMETER SkipGuestIPConfig
    Skip automated guest OS IP configuration. Default is $false.

.PARAMETER WhatIf
    Shows what would be done without making any changes.

.EXAMPLE
    .\Invoke-VMigration.ps1 -CSVPath "C:\VMMigration.csv" -SourcevCenter "vcenter7.domain.com" -TargetvCenter "vcenter8.domain.com" -TargetONTAPCluster "ontap-cluster.domain.com" -TargetNFSSVM "nfs_svm" -WhatIf

.EXAMPLE
    .\Invoke-VMigration.ps1 -CSVPath "VMs.csv" -SourcevCenter "source-vc.domain.com" -TargetvCenter "target-vc.domain.com" -TargetONTAPCluster "target-ontap.domain.com" -TargetNFSSVM "migration_svm"

.EXAMPLE
    .\Invoke-VMigration.ps1 -CSVPath "VMs.csv" -SourcevCenter "source-vc.domain.com" -TargetvCenter "target-vc.domain.com" -TargetONTAPCluster "target-ontap.domain.com" -TargetNFSSVM "migration_svm" -SkipGuestIPConfig

.NOTES
    Author: PowerShell Automation
    Version: 1.0
    Requires: VMware.PowerCLI, NetApp.ONTAP modules
    
    This script requires administrative privileges and proper credentials for:
    - Source vCenter Server
    - Target vCenter Server  
    - Target NetApp ONTAP Cluster
    - Guest Operating Systems (for automated IP configuration)
    
    Supported guest operating systems for automated IP configuration:
    - Windows Server 2012 R2 and later
    - Linux distributions with NetworkManager, systemd-networkd, or traditional networking
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({Test-Path ${_}})]
    [string]$CSVPath,
    
    [Parameter(Mandatory = $true)]
    [string]$SourcevCenter,
    
    [Parameter(Mandatory = $true)]
    [string]$TargetvCenter,
    
    [Parameter(Mandatory = $true)]
    [string]$TargetONTAPCluster,
    
    [Parameter(Mandatory = $true)]
    [string]$TargetNFSSVM,
    
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\VMMigration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log",
    
    [Parameter(Mandatory = $false)]
    [string]$BackupTier = "Tier3",
    
    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$GuestCredentials,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipGuestIPConfig,
    
    [switch]$WhatIf
)

# Global Variables
$script:LogFile = $LogPath
$script:MigrationData = @()
$script:SourceVIServer = $null
$script:TargetVIServer = $null
$script:ONTAPConnection = $null
$script:ErrorCount = 0
$script:WarningCount = 0

# Import required modules
$RequiredModules = @('VMware.PowerCLI', 'NetApp.ONTAP')

#region Helper Functions

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    
    # Write to log file
    Add-Content -Path $script:LogFile -Value $LogEntry
    
    # Write to console with color coding
    switch ($Level) {
        "INFO"    { Write-Host $LogEntry -ForegroundColor White }
        "SUCCESS" { Write-Host $LogEntry -ForegroundColor Green }
        "WARNING" { 
            Write-Host $LogEntry -ForegroundColor Yellow
            $script:WarningCount++
        }
        "ERROR"   { 
            Write-Host $LogEntry -ForegroundColor Red
            $script:ErrorCount++
        }
    }
}

function Test-Prerequisites {
    [CmdletBinding()]
    param()
    
    Write-Log "Checking prerequisites..." -Level "INFO"
    
    # Check required modules
    foreach ($Module in $RequiredModules) {
        try {
            if (Get-Module -ListAvailable -Name $Module) {
                Import-Module $Module -Force
                Write-Log "Module ${Module} imported successfully" -Level "SUCCESS"
            } else {
                Write-Log "Required module ${Module} is not installed. Please install it using: Install-Module ${Module} -Force" -Level "ERROR"
                return $false
            }
        }
        catch {
            Write-Log "Failed to import module ${Module}: ${_}" -Level "ERROR"
            return $false
        }
    }
    
    # Test CSV file format
    try {
        $TestCSV = Import-Csv -Path $CSVPath
        $RequiredColumns = @('VMName', 'VMDatastore', 'TargetVLAN', 'TargetIP', 'TargetSNMask', 'TargetGW', 'TargetDNS1', 'TargetDNS2')
        
        $CSVColumns = $TestCSV | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
        
        foreach ($Column in $RequiredColumns) {
            if ($Column -notin $CSVColumns) {
                Write-Log "Required column '${Column}' not found in CSV file" -Level "ERROR"
                return $false
            }
        }
        
        Write-Log "CSV file format validation passed. Found $($TestCSV.Count) VMs to migrate" -Level "SUCCESS"
        $script:MigrationData = $TestCSV
    }
    catch {
        Write-Log "Failed to validate CSV file: ${_}" -Level "ERROR"
        return $false
    }
    
    return $true
}

function Get-Credentials {
    [CmdletBinding()]
    param()
    
    Write-Log "Collecting credentials..." -Level "INFO"
    
    # Source vCenter credentials
    Write-Host "`nEnter credentials for Source vCenter (${SourcevCenter}):" -ForegroundColor Yellow
    $script:SourcevCenterCredentials = Get-Credential -Message "Source vCenter Credentials"
    
    # Target vCenter credentials  
    Write-Host "`nEnter credentials for Target vCenter (${TargetvCenter}):" -ForegroundColor Yellow
    $script:TargetvCenterCredentials = Get-Credential -Message "Target vCenter Credentials"
    
    # Target ONTAP credentials
    Write-Host "`nEnter credentials for Target ONTAP Cluster (${TargetONTAPCluster}):" -ForegroundColor Yellow
    $script:ONTAPCredentials = Get-Credential -Message "ONTAP Cluster Credentials"
    
    # Guest OS credentials (if not provided and not skipping IP config)
    if (-not $GuestCredentials -and -not $SkipGuestIPConfig) {
        Write-Host "`nEnter credentials for Guest OS operations (Local Admin or Domain Admin):" -ForegroundColor Yellow
        $script:GuestOSCredentials = Get-Credential -Message "Guest OS Credentials"
    } elseif ($GuestCredentials) {
        $script:GuestOSCredentials = $GuestCredentials
    }
    
    Write-Log "Credentials collected successfully" -Level "SUCCESS"
}

function Connect-Infrastructure {
    [CmdletBinding()]
    param()
    
    Write-Log "Connecting to infrastructure components..." -Level "INFO"
    
    try {
        # Connect to Source vCenter
        Write-Log "Connecting to Source vCenter: ${SourcevCenter}" -Level "INFO"
        if (-not $WhatIf) {
            $script:SourceVIServer = Connect-VIServer -Server $SourcevCenter -Credential $script:SourcevCenterCredentials -ErrorAction Stop
            Write-Log "Successfully connected to Source vCenter" -Level "SUCCESS"
        } else {
            Write-Log "[WHATIF] Would connect to Source vCenter: ${SourcevCenter}" -Level "INFO"
        }
        
        # Connect to Target vCenter
        Write-Log "Connecting to Target vCenter: ${TargetvCenter}" -Level "INFO" 
        if (-not $WhatIf) {
            $script:TargetVIServer = Connect-VIServer -Server $TargetvCenter -Credential $script:TargetvCenterCredentials -ErrorAction Stop
            Write-Log "Successfully connected to Target vCenter" -Level "SUCCESS"
        } else {
            Write-Log "[WHATIF] Would connect to Target vCenter: ${TargetvCenter}" -Level "INFO"
        }
        
        # Connect to ONTAP Cluster
        Write-Log "Connecting to ONTAP Cluster: ${TargetONTAPCluster}" -Level "INFO"
        if (-not $WhatIf) {
            $script:ONTAPConnection = Connect-NcController -Name $TargetONTAPCluster -Credential $script:ONTAPCredentials -ErrorAction Stop
            Write-Log "Successfully connected to ONTAP Cluster" -Level "SUCCESS"
        } else {
            Write-Log "[WHATIF] Would connect to ONTAP Cluster: ${TargetONTAPCluster}" -Level "INFO"
        }
        
        return $true
    }
    catch {
        Write-Log "Failed to connect to infrastructure: ${_}" -Level "ERROR"
        return $false
    }
}

function Get-SourceDatastores {
    [CmdletBinding()]
    param()
    
    Write-Log "Step 1: Discovering NFS Datastores for VMs to be migrated..." -Level "INFO"
    
    $UniqueDatastores = $script:MigrationData | Select-Object -ExpandProperty VMDatastore -Unique
    $DiscoveredDatastores = @{}
    
    foreach ($DatastoreName in $UniqueDatastores) {
        try {
            if (-not $WhatIf) {
                $Datastore = Get-Datastore -Server $script:SourceVIServer -Name $DatastoreName -ErrorAction Stop
                $DiscoveredDatastores[$DatastoreName] = $Datastore
                Write-Log "Found datastore: ${DatastoreName} (Type: $($Datastore.Type), Capacity: $([math]::Round($Datastore.CapacityGB, 2)) GB)" -Level "SUCCESS"
            } else {
                Write-Log "[WHATIF] Would discover datastore: ${DatastoreName}" -Level "INFO"
                $DiscoveredDatastores[$DatastoreName] = $null
            }
        }
        catch {
            Write-Log "Failed to find datastore ${DatastoreName}: ${_}" -Level "ERROR"
            return $null
        }
    }
    
    Write-Log "Successfully discovered $($DiscoveredDatastores.Count) unique datastores" -Level "SUCCESS"
    return $DiscoveredDatastores
}

function Stop-SourceVMs {
    [CmdletBinding()]
    param()
    
    Write-Log "Step 2: Powering off VMs in source vCenter..." -Level "INFO"
    
    $StoppedVMs = @()
    
    foreach ($VM in $script:MigrationData) {
        try {
            if (-not $WhatIf) {
                $VMObject = Get-VM -Server $script:SourceVIServer -Name $VM.VMName -ErrorAction Stop
                
                if ($VMObject.PowerState -eq "PoweredOn") {
                    Write-Log "Shutting down VM: $($VM.VMName)" -Level "INFO"
                    $VMObject | Shutdown-VMGuest -Confirm:$false | Out-Null
                    
                    # Wait for graceful shutdown with timeout
                    $Timeout = 300 # 5 minutes
                    $Timer = 0
                    do {
                        Start-Sleep -Seconds 10
                        $Timer += 10
                        $VMObject = Get-VM -Server $script:SourceVIServer -Name $VM.VMName
                        Write-Log "Waiting for VM $($VM.VMName) to shut down... ($Timer/$Timeout seconds)" -Level "INFO"
                    } while ($VMObject.PowerState -eq "PoweredOn" -and $Timer -lt $Timeout)
                    
                    # Force power off if graceful shutdown failed
                    if ($VMObject.PowerState -eq "PoweredOn") {
                        Write-Log "Graceful shutdown timeout reached. Force powering off VM: $($VM.VMName)" -Level "WARNING"
                        $VMObject | Stop-VM -Confirm:$false | Out-Null
                    }
                    
                    $StoppedVMs += $VM.VMName
                    Write-Log "VM $($VM.VMName) powered off successfully" -Level "SUCCESS"
                } else {
                    Write-Log "VM $($VM.VMName) is already powered off" -Level "INFO"
                }
            } else {
                Write-Log "[WHATIF] Would power off VM: $($VM.VMName)" -Level "INFO"
            }
        }
        catch {
            Write-Log "Failed to power off VM $($VM.VMName): ${_}" -Level "ERROR"
        }
    }
    
    Write-Log "Completed powering off VMs. Successfully stopped: $($StoppedVMs.Count)" -Level "SUCCESS"
    return $StoppedVMs
}

function Update-SnapMirrorRelationships {
    [CmdletBinding()]
    param(
        [hashtable]$Datastores
    )
    
    Write-Log "Step 3: Updating/quiescing/breaking SnapMirror relationships..." -Level "INFO"
    
    $ProcessedVolumes = @()
    
    foreach ($DatastoreName in $Datastores.Keys) {
        try {
            if (-not $WhatIf) {
                # Find SnapMirror relationships for this datastore
                $SnapMirrorRelations = Get-NcSnapmirror -DestinationVserver $TargetNFSSVM | Where-Object { 
                    $_.DestinationVolume -like "*$DatastoreName*" 
                }
                
                foreach ($Relation in $SnapMirrorRelations) {
                    Write-Log "Processing SnapMirror relationship: $($Relation.SourcePath) -> $($Relation.DestinationPath)" -Level "INFO"
                    
                    # Update the relationship
                    Write-Log "Updating SnapMirror relationship for volume: $($Relation.DestinationVolume)" -Level "INFO"
                    Invoke-NcSnapmirrorUpdate -DestinationPath $Relation.DestinationPath | Out-Null
                    
                    # Wait for update to complete
                    do {
                        Start-Sleep -Seconds 10
                        $Status = Get-NcSnapmirror -DestinationPath $Relation.DestinationPath
                        Write-Log "Waiting for SnapMirror update to complete. Status: $($Status.RelationshipStatus)" -Level "INFO"
                    } while ($Status.RelationshipStatus -eq "Transferring")
                    
                    # Quiesce the relationship
                    Write-Log "Quiescing SnapMirror relationship for volume: $($Relation.DestinationVolume)" -Level "INFO"
                    Invoke-NcSnapmirrorQuiesce -DestinationPath $Relation.DestinationPath | Out-Null
                    
                    # Break the relationship
                    Write-Log "Breaking SnapMirror relationship for volume: $($Relation.DestinationVolume)" -Level "INFO" 
                    Invoke-NcSnapmirrorBreak -DestinationPath $Relation.DestinationPath | Out-Null
                    
                    $ProcessedVolumes += $Relation.DestinationVolume
                    Write-Log "Successfully processed SnapMirror relationship for volume: $($Relation.DestinationVolume)" -Level "SUCCESS"
                }
            } else {
                Write-Log "[WHATIF] Would update/quiesce/break SnapMirror relationships for datastore: ${DatastoreName}" -Level "INFO"
            }
        }
        catch {
            Write-Log "Failed to process SnapMirror relationships for datastore ${DatastoreName}: ${_}" -Level "ERROR"
        }
    }
    
    Write-Log "Completed SnapMirror operations. Processed volumes: $($ProcessedVolumes.Count)" -Level "SUCCESS"
    return $ProcessedVolumes
}

function Mount-TargetDatastores {
    [CmdletBinding()]
    param(
        [hashtable]$Datastores
    )
    
    Write-Log "Step 4: Mounting NFS datastores on target cluster..." -Level "INFO"
    
    $MountedDatastores = @()
    
    foreach ($DatastoreName in $Datastores.Keys) {
        try {
            if (-not $WhatIf) {
                # Get NFS export path from ONTAP
                $Volume = Get-NcVol -VserverContext $TargetNFSSVM | Where-Object { 
                    $_.Name -like "*$DatastoreName*" 
                } | Select-Object -First 1
                
                if ($Volume) {
                    $NFSExportPath = "/$($Volume.Name)"
                    $NFSServer = (Get-NcNetInterface -VserverContext $TargetNFSSVM | Where-Object { 
                        $_.Role -eq "data" -and $_.DataProtocols -contains "nfs" 
                    } | Select-Object -First 1).Address
                    
                    Write-Log "Mounting NFS datastore: ${DatastoreName} from ${NFSServer}:${NFSExportPath}" -Level "INFO"
                    
                    # Get target cluster hosts
                    $VMHosts = Get-VMHost -Server $script:TargetVIServer
                    foreach ($VMHost in $VMHosts) {
                        $NewDatastore = New-Datastore -VMHost $VMHost -Name $DatastoreName -Nfs -NfsHost $NFSServer -Path $NFSExportPath
                        Write-Log "Mounted NFS datastore ${DatastoreName} on host $($VMHost.Name)" -Level "SUCCESS"
                    }
                    
                    $MountedDatastores += $DatastoreName
                } else {
                    Write-Log "Could not find matching volume for datastore: ${DatastoreName}" -Level "ERROR"
                }
            } else {
                Write-Log "[WHATIF] Would mount NFS datastore: ${DatastoreName}" -Level "INFO"
            }
        }
        catch {
            Write-Log "Failed to mount datastore ${DatastoreName}: ${_}" -Level "ERROR"
        }
    }
    
    Write-Log "Completed datastore mounting. Successfully mounted: $($MountedDatastores.Count)" -Level "SUCCESS"
    return $MountedDatastores
}

function Register-TargetVMs {
    [CmdletBinding()]
    param()
    
    Write-Log "Step 5: Registering VMs in target vCenter..." -Level "INFO"
    
    $RegisteredVMs = @()
    
    foreach ($VM in $script:MigrationData) {
        try {
            if (-not $WhatIf) {
                # Find the VM's VMX file in the target datastore
                $Datastore = Get-Datastore -Server $script:TargetVIServer -Name $VM.VMDatastore -ErrorAction Stop
                $VMXPath = "[$($VM.VMDatastore)] $($VM.VMName)/$($VM.VMName).vmx"
                
                Write-Log "Registering VM: $($VM.VMName) from path: ${VMXPath}" -Level "INFO"
                
                # Get a target host for registration
                $TargetHost = Get-VMHost -Server $script:TargetVIServer | Select-Object -First 1
                
                # Register the VM
                $RegisteredVM = New-VM -VMFilePath $VMXPath -VMHost $TargetHost -Location (Get-Folder -Server $script:TargetVIServer -Name "vm")
                
                $RegisteredVMs += $VM.VMName
                Write-Log "Successfully registered VM: $($VM.VMName)" -Level "SUCCESS"
            } else {
                Write-Log "[WHATIF] Would register VM: $($VM.VMName)" -Level "INFO"
            }
        }
        catch {
            Write-Log "Failed to register VM $($VM.VMName): ${_}" -Level "ERROR"
        }
    }
    
    Write-Log "Completed VM registration. Successfully registered: $($RegisteredVMs.Count)" -Level "SUCCESS"
    return $RegisteredVMs
}

function Update-VMNetworkConfiguration {
    [CmdletBinding()]
    param()
    
    Write-Log "Step 6: Updating VM network configurations..." -Level "INFO"
    
    $UpdatedVMs = @()
    
    foreach ($VM in $script:MigrationData) {
        try {
            if (-not $WhatIf) {
                $VMObject = Get-VM -Server $script:TargetVIServer -Name $VM.VMName -ErrorAction Stop
                
                Write-Log "Updating network configuration for VM: $($VM.VMName)" -Level "INFO"
                
                # Get the VM's network adapter
                $NetworkAdapter = Get-NetworkAdapter -VM $VMObject | Select-Object -First 1
                
                # Get or create the target port group
                $TargetPortGroup = Get-VDPortgroup -Server $script:TargetVIServer -Name $VM.TargetVLAN -ErrorAction SilentlyContinue
                if (-not $TargetPortGroup) {
                    Write-Log "Port group $($VM.TargetVLAN) not found. Please ensure it exists before proceeding." -Level "ERROR"
                    continue
                }
                
                # Update network adapter to new VLAN
                $NetworkAdapter | Set-NetworkAdapter -Portgroup $TargetPortGroup -Confirm:$false | Out-Null
                
                Write-Log "Updated VM $($VM.VMName) to VLAN: $($VM.TargetVLAN)" -Level "SUCCESS"
                $UpdatedVMs += $VM.VMName
            } else {
                Write-Log "[WHATIF] Would update network configuration for VM: $($VM.VMName) to VLAN: $($VM.TargetVLAN)" -Level "INFO"
            }
        }
        catch {
            Write-Log "Failed to update network configuration for VM $($VM.VMName): ${_}" -Level "ERROR"
        }
    }
    
    Write-Log "Completed network configuration updates. Successfully updated: $($UpdatedVMs.Count)" -Level "SUCCESS"
    return $UpdatedVMs
}

function Start-TargetVMs {
    [CmdletBinding()]
    param()
    
    Write-Log "Step 7: Powering on VMs and answering relocation questions..." -Level "INFO"
    
    $StartedVMs = @()
    
    foreach ($VM in $script:MigrationData) {
        try {
            if (-not $WhatIf) {
                $VMObject = Get-VM -Server $script:TargetVIServer -Name $VM.VMName -ErrorAction Stop
                
                Write-Log "Powering on VM: $($VM.VMName)" -Level "INFO"
                Start-VM -VM $VMObject -Confirm:$false | Out-Null
                
                # Wait for VM to start and check for questions
                Start-Sleep -Seconds 30
                
                # Check for and answer VM questions (I moved it)
                $VMView = Get-View -VIObject $VMObject
                if ($VMView.Runtime.Question) {
                    Write-Log "Answering VM question for $($VM.VMName): I moved it" -Level "INFO"
                    $VMView.AnswerVM($VMView.Runtime.Question.Id, "0") # "0" typically means "I moved it"
                }
                
                # Wait for VMware Tools to be ready
                Write-Log "Waiting for VMware Tools to be ready on $($VM.VMName)..." -Level "INFO"
                $Timeout = 300 # 5 minutes
                $Timer = 0
                do {
                    Start-Sleep -Seconds 15
                    $Timer += 15
                    $VMObject = Get-VM -Server $script:TargetVIServer -Name $VM.VMName
                    Write-Log "Waiting for VMware Tools on $($VM.VMName)... Status: $($VMObject.ExtensionData.Guest.ToolsStatus) ($Timer/$Timeout seconds)" -Level "INFO"
                } while ($VMObject.ExtensionData.Guest.ToolsStatus -ne "toolsOk" -and $Timer -lt $Timeout)
                
                if ($VMObject.ExtensionData.Guest.ToolsStatus -eq "toolsOk") {
                    Write-Log "VMware Tools ready on $($VM.VMName)" -Level "SUCCESS"
                } else {
                    Write-Log "VMware Tools timeout on $($VM.VMName). Continuing anyway..." -Level "WARNING"
                }
                
                $StartedVMs += $VM.VMName  
                Write-Log "Successfully started VM: $($VM.VMName)" -Level "SUCCESS"
            } else {
                Write-Log "[WHATIF] Would power on VM: $($VM.VMName) and answer relocation question" -Level "INFO"
            }
        }
        catch {
            Write-Log "Failed to start VM $($VM.VMName): ${_}" -Level "ERROR"
        }
    }
    
    Write-Log "Completed powering on VMs. Successfully started: $($StartedVMs.Count)" -Level "SUCCESS"
    return $StartedVMs
}

function Set-GuestIPConfiguration {
    [CmdletBinding()]
    param()
    
    Write-Log "Step 7.5: Configuring guest OS IP settings..." -Level "INFO"
    
    if ($SkipGuestIPConfig) {
        Write-Log "Skipping guest IP configuration per parameter" -Level "INFO"
        return @()
    }
    
    if (-not $script:GuestOSCredentials) {
        Write-Log "No guest credentials provided. Skipping IP configuration" -Level "WARNING"
        return @()
    }
    
    $ConfiguredVMs = @()
    
    foreach ($VM in $script:MigrationData) {
        try {
            if (-not $WhatIf) {
                $VMObject = Get-VM -Server $script:TargetVIServer -Name $VM.VMName -ErrorAction Stop
                
                # Skip if VMware Tools is not ready
                if ($VMObject.ExtensionData.Guest.ToolsStatus -ne "toolsOk") {
                    Write-Log "VMware Tools not ready on $($VM.VMName). Skipping IP configuration" -Level "WARNING"
                    continue
                }
                
                Write-Log "Configuring IP settings for VM: $($VM.VMName)" -Level "INFO"
                
                # Detect guest OS type
                $GuestOS = $VMObject.ExtensionData.Guest.GuestFamily
                Write-Log "Detected guest OS family: ${GuestOS} for VM: $($VM.VMName)" -Level "INFO"
                
                if ($GuestOS -eq "windowsGuest") {
                    # Windows IP configuration
                    $WindowsScript = @"
# Configure Windows network settings
`$ErrorActionPreference = 'Stop'
try {
    # Get the primary network adapter
    `$Adapter = Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' -and `$_.Name -like '*Ethernet*' } | Select-Object -First 1
    
    if (`$Adapter) {
        Write-Host "Configuring adapter: `$(`$Adapter.Name)"
        
        # Remove existing IP configuration
        Remove-NetIPAddress -InterfaceAlias `$Adapter.Name -Confirm:`$false -ErrorAction SilentlyContinue
        Remove-NetRoute -InterfaceAlias `$Adapter.Name -Confirm:`$false -ErrorAction SilentlyContinue
        
        # Set new IP configuration
        New-NetIPAddress -InterfaceAlias `$Adapter.Name -IPAddress "$($VM.TargetIP)" -PrefixLength $(Get-PrefixLength "$($VM.TargetSNMask)") -DefaultGateway "$($VM.TargetGW)" | Out-Null
        
        # Set DNS servers
        Set-DnsClientServerAddress -InterfaceAlias `$Adapter.Name -ServerAddresses "$($VM.TargetDNS1)","$($VM.TargetDNS2)" | Out-Null
        
        # Test connectivity
        `$TestResult = Test-NetConnection -ComputerName "$($VM.TargetGW)" -InformationLevel Quiet
        if (`$TestResult) {
            Write-Host "Network configuration successful - Gateway reachable"
        } else {
            Write-Host "Warning: Gateway not reachable after configuration"
        }
        
        # Output current configuration
        Get-NetIPAddress -InterfaceAlias `$Adapter.Name -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength
        Get-NetRoute -InterfaceAlias `$Adapter.Name | Where-Object { `$_.DestinationPrefix -eq '0.0.0.0/0' } | Select-Object NextHop
    } else {
        Write-Host "Error: No active Ethernet adapter found"
        exit 1
    }
} catch {
    Write-Host "Error configuring network: `$(`$_.Exception.Message)"
    exit 1
}

function Get-PrefixLength {
    param(`$SubnetMask)
    `$Bits = 0
    `$SubnetMask.Split('.') | ForEach-Object {
        `$Octet = [int]`$_
        while (`$Octet -gt 0) {
            `$Bits += `$Octet -band 1
            `$Octet = `$Octet -shr 1
        }
    }
    return `$Bits
}
"@
                    
                    Write-Log "Executing Windows IP configuration script on $($VM.VMName)" -Level "INFO"
                    $Result = Invoke-VMScript -VM $VMObject -ScriptText $WindowsScript -GuestCredential $script:GuestOSCredentials -ScriptType PowerShell
                    
                } elseif ($GuestOS -eq "linuxGuest") {
                    # Linux IP configuration (supports most modern distributions)
                    $LinuxScript = @"
#!/bin/bash
set -e

# Function to detect network manager
detect_network_manager() {
    if systemctl is-active --quiet NetworkManager; then
        echo "NetworkManager"
    elif systemctl is-active --quiet networking; then
        echo "networking"
    elif systemctl is-active --quiet systemd-networkd; then
        echo "systemd-networkd"
    else
        echo "unknown"
    fi
}

# Get primary interface
INTERFACE=`$(ip route | grep default | awk '{print `$5}' | head -n1)
if [ -z "`$INTERFACE" ]; then
    INTERFACE=`$(ip link show | grep -E '^[0-9]+: (eth|ens|eno|enp)' | head -n1 | awk -F': ' '{print `$2}')
fi

if [ -z "`$INTERFACE" ]; then
    echo "Error: Could not determine primary network interface"
    exit 1
fi

echo "Configuring interface: `$INTERFACE"

# Convert subnet mask to CIDR
subnet_to_cidr() {
    local subnet=`$1
    local cidr=0
    IFS=. read -r a b c d <<< "`$subnet"
    for octet in `$a `$b `$c `$d; do
        while [ `$octet -ne 0 ]; do
            cidr=`$((cidr + (octet & 1)))
            octet=`$((octet >> 1))
        done
    done
    echo `$cidr
}

CIDR=`$(subnet_to_cidr "$($VM.TargetSNMask)")
NETWORK_MANAGER=`$(detect_network_manager)

echo "Detected network manager: `$NETWORK_MANAGER"

case `$NETWORK_MANAGER in
    "NetworkManager")
        # Use nmcli for NetworkManager
        CONNECTION=`$(nmcli -t -f NAME connection show --active | head -n1)
        if [ -n "`$CONNECTION" ]; then
            nmcli connection modify "`$CONNECTION" ipv4.addresses "$($VM.TargetIP)/`$CIDR"
            nmcli connection modify "`$CONNECTION" ipv4.gateway "$($VM.TargetGW)"
            nmcli connection modify "`$CONNECTION" ipv4.dns "$($VM.TargetDNS1),$($VM.TargetDNS2)"
            nmcli connection modify "`$CONNECTION" ipv4.method manual
            nmcli connection up "`$CONNECTION"
        else
            echo "Error: No active NetworkManager connection found"
            exit 1
        fi
        ;;
    "networking")
        # Traditional /etc/network/interfaces (Debian/Ubuntu)
        cat > /etc/network/interfaces.d/`$INTERFACE << EOF
auto `$INTERFACE
iface `$INTERFACE inet static
address $($VM.TargetIP)
netmask $($VM.TargetSNMask)
gateway $($VM.TargetGW)
dns-nameservers $($VM.TargetDNS1) $($VM.TargetDNS2)
EOF
        systemctl restart networking
        ;;
    "systemd-networkd")
        # systemd-networkd configuration
        cat > /etc/systemd/network/20-wired.network << EOF
[Match]
Name=`$INTERFACE

[Network]
Address=$($VM.TargetIP)/`$CIDR
Gateway=$($VM.TargetGW)
DNS=$($VM.TargetDNS1)
DNS=$($VM.TargetDNS2)
EOF
        systemctl restart systemd-networkd
        ;;
    *)
        # Fallback to manual configuration
        ip addr flush dev `$INTERFACE
        ip addr add $($VM.TargetIP)/`$CIDR dev `$INTERFACE
        ip route add default via $($VM.TargetGW) dev `$INTERFACE
        echo "nameserver $($VM.TargetDNS1)" > /etc/resolv.conf
        echo "nameserver $($VM.TargetDNS2)" >> /etc/resolv.conf
        ;;
esac

# Test connectivity
echo "Testing network configuration..."
ping -c 2 "$($VM.TargetGW)" > /dev/null 2>&1
if [ `$? -eq 0 ]; then
    echo "Network configuration successful - Gateway reachable"
else
    echo "Warning: Gateway not reachable after configuration"
fi

# Show current configuration
echo "Current IP configuration:"
ip addr show `$INTERFACE | grep -E 'inet '
ip route show default
"@
                    
                    Write-Log "Executing Linux IP configuration script on $($VM.VMName)" -Level "INFO"
                    $Result = Invoke-VMScript -VM $VMObject -ScriptText $LinuxScript -GuestCredential $script:GuestOSCredentials -ScriptType Bash
                    
                } else {
                    Write-Log "Unsupported guest OS family '${GuestOS}' for VM $($VM.VMName). Skipping IP configuration" -Level "WARNING"
                    continue
                }
                
                # Check script execution result
                if ($Result.ExitCode -eq 0) {
                    Write-Log "Successfully configured IP settings for $($VM.VMName): $($VM.TargetIP)" -Level "SUCCESS"
                    Write-Log "Script output: $($Result.ScriptOutput)" -Level "INFO"
                    $ConfiguredVMs += $VM.VMName
                } else {
                    Write-Log "Failed to configure IP for $($VM.VMName). Exit code: $($Result.ExitCode)" -Level "ERROR"
                    Write-Log "Error output: $($Result.ScriptOutput)" -Level "ERROR"
                }
                
            } else {
                Write-Log "[WHATIF] Would configure IP settings for VM: $($VM.VMName) to IP: $($VM.TargetIP)" -Level "INFO"
            }
        }
        catch {
            Write-Log "Failed to configure IP for VM $($VM.VMName): ${_}" -Level "ERROR"
        }
    }
    
    Write-Log "Completed guest IP configuration. Successfully configured: $($ConfiguredVMs.Count)" -Level "SUCCESS"
    return $ConfiguredVMs
}

function Add-BackupTags {
    [CmdletBinding()]
    param()
    
    Write-Log "Step 8: Adding backup tags to VMs..." -Level "INFO"
    
    $TaggedVMs = @()
    
    try {
        if (-not $WhatIf) {
            # Create backup tag category if it doesn't exist
            $TagCategory = Get-TagCategory -Name "Backup" -ErrorAction SilentlyContinue
            if (-not $TagCategory) {
                $TagCategory = New-TagCategory -Name "Backup" -Cardinality Single -EntityType VirtualMachine
                Write-Log "Created backup tag category" -Level "INFO"
            }
            
            # Create backup tier tag if it doesn't exist
            $BackupTag = Get-Tag -Category $TagCategory -Name $BackupTier -ErrorAction SilentlyContinue
            if (-not $BackupTag) {
                $BackupTag = New-Tag -Category $TagCategory -Name $BackupTier
                Write-Log "Created backup tag: ${BackupTier}" -Level "INFO"
            }
        }
        
        foreach ($VM in $script:MigrationData) {
            try {
                if (-not $WhatIf) {
                    $VMObject = Get-VM -Server $script:TargetVIServer -Name $VM.VMName -ErrorAction Stop
                    New-TagAssignment -Tag $BackupTag -Entity $VMObject | Out-Null
                    
                    $TaggedVMs += $VM.VMName
                    Write-Log "Applied backup tag '${BackupTier}' to VM: $($VM.VMName)" -Level "SUCCESS"
                } else {
                    Write-Log "[WHATIF] Would apply backup tag '${BackupTier}' to VM: $($VM.VMName)" -Level "INFO"
                }
            }
            catch {
                Write-Log "Failed to tag VM $($VM.VMName): ${_}" -Level "ERROR"
            }
        }
    }
    catch {
        Write-Log "Failed to create backup tags: ${_}" -Level "ERROR"
    }
    
    Write-Log "Completed backup tagging. Successfully tagged: $($TaggedVMs.Count)" -Level "SUCCESS"
    return $TaggedVMs
}

function Disconnect-SourceVMNetworks {
    [CmdletBinding()]
    param()
    
    Write-Log "Step 9: Disconnecting source VM network adapters..." -Level "INFO"
    
    # Prompt for confirmation
    if (-not $WhatIf) {
        $Confirmation = Read-Host "Migration appears successful. Disconnect source VM networks? (y/N)"
        if ($Confirmation -ne 'y' -and $Confirmation -ne 'Y') {
            Write-Log "Skipping source VM network disconnection per user request" -Level "WARNING"
            return @()
        }
    }
    
    $DisconnectedVMs = @()
    
    foreach ($VM in $script:MigrationData) {
        try {
            if (-not $WhatIf) {
                $VMObject = Get-VM -Server $script:SourceVIServer -Name $VM.VMName -ErrorAction Stop
                $NetworkAdapters = Get-NetworkAdapter -VM $VMObject
                
                foreach ($Adapter in $NetworkAdapters) {
                    $Adapter | Set-NetworkAdapter -Connected:$false -Confirm:$false | Out-Null
                    Write-Log "Disconnected network adapter for VM: $($VM.VMName)" -Level "SUCCESS"
                }
                
                $DisconnectedVMs += $VM.VMName
            } else {
                Write-Log "[WHATIF] Would disconnect network adapters for VM: $($VM.VMName)" -Level "INFO"
            }
        }
        catch {
            Write-Log "Failed to disconnect network for VM $($VM.VMName): ${_}" -Level "ERROR"
        }
    }
    
    Write-Log "Completed network disconnection. Successfully disconnected: $($DisconnectedVMs.Count)" -Level "SUCCESS"
    return $DisconnectedVMs
}

function Unregister-SourceVMs {
    [CmdletBinding()]
    param()
    
    Write-Log "Step 10: Unregistering VMs from source vCenter..." -Level "INFO"
    
    # Prompt for confirmation
    if (-not $WhatIf) {
        $Confirmation = Read-Host "Final step: Unregister VMs from source vCenter? This cannot be easily undone. (y/N)"
        if ($Confirmation -ne 'y' -and $Confirmation -ne 'Y') {
            Write-Log "Skipping source VM unregistration per user request" -Level "WARNING"
            return @()
        }
    }
    
    $UnregisteredVMs = @()
    
    foreach ($VM in $script:MigrationData) {
        try {
            if (-not $WhatIf) {
                $VMObject = Get-VM -Server $script:SourceVIServer -Name $VM.VMName -ErrorAction Stop
                Remove-VM -VM $VMObject -DeletePermanently:$false -Confirm:$false | Out-Null
                
                $UnregisteredVMs += $VM.VMName
                Write-Log "Successfully unregistered VM: $($VM.VMName)" -Level "SUCCESS"
            } else {
                Write-Log "[WHATIF] Would unregister VM: $($VM.VMName)" -Level "INFO"
            }
        }
        catch {
            Write-Log "Failed to unregister VM $($VM.VMName): ${_}" -Level "ERROR"
        }
    }
    
    Write-Log "Completed VM unregistration. Successfully unregistered: $($UnregisteredVMs.Count)" -Level "SUCCESS"
    return $UnregisteredVMs
}

function Disconnect-Infrastructure {
    [CmdletBinding()]
    param()
    
    Write-Log "Disconnecting from infrastructure components..." -Level "INFO"
    
    try {
        if ($script:SourceVIServer) {
            Disconnect-VIServer -Server $script:SourceVIServer -Confirm:$false
            Write-Log "Disconnected from source vCenter" -Level "SUCCESS"
        }
        
        if ($script:TargetVIServer) {
            Disconnect-VIServer -Server $script:TargetVIServer -Confirm:$false  
            Write-Log "Disconnected from target vCenter" -Level "SUCCESS"
        }
        
        if ($script:ONTAPConnection) {
            # NetApp connections are automatically managed
            Write-Log "NetApp ONTAP connection closed" -Level "SUCCESS"
        }
    }
    catch {
        Write-Log "Error during infrastructure disconnect: ${_}" -Level "WARNING"
    }
}

function Write-MigrationSummary {
    [CmdletBinding()]
    param()
    
    $TotalVMs = $script:MigrationData.Count
    
    Write-Log "`n" + "="*80 -Level "INFO"
    Write-Log "VM MIGRATION SUMMARY" -Level "INFO" 
    Write-Log "="*80 -Level "INFO"
    Write-Log "Total VMs to migrate: ${TotalVMs}" -Level "INFO"
    Write-Log "Errors encountered: $($script:ErrorCount)" -Level "INFO"
    Write-Log "Warnings encountered: $($script:WarningCount)" -Level "INFO"
    Write-Log "Log file location: $($script:LogFile)" -Level "INFO"
    Write-Log "Migration completed at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level "INFO"
    Write-Log "="*80 -Level "INFO"
    
    if ($script:ErrorCount -eq 0) {
        Write-Log "MIGRATION COMPLETED SUCCESSFULLY!" -Level "SUCCESS"
    } elseif ($script:ErrorCount -lt $TotalVMs) {
        Write-Log "MIGRATION COMPLETED WITH SOME ERRORS - PLEASE REVIEW LOG" -Level "WARNING"
    } else {
        Write-Log "MIGRATION FAILED - PLEASE REVIEW LOG AND RETRY" -Level "ERROR"
    }
}

#endregion

#region Main Execution

# Initialize logging
Write-Log "Starting VM Migration Process..." -Level "INFO"
Write-Log "Source vCenter: ${SourcevCenter}" -Level "INFO"
Write-Log "Target vCenter: ${TargetvCenter}" -Level "INFO"
Write-Log "Target ONTAP Cluster: ${TargetONTAPCluster}" -Level "INFO"
Write-Log "Target NFS SVM: ${TargetNFSSVM}" -Level "INFO"
Write-Log "CSV Path: ${CSVPath}" -Level "INFO"
Write-Log "WhatIf Mode: ${WhatIf}" -Level "INFO"

try {
    # Step 0: Prerequisites and Setup
    if (-not (Test-Prerequisites)) {
        Write-Log "Prerequisites check failed. Exiting." -Level "ERROR"
        exit 1
    }
    
    if (-not $WhatIf) {
        Get-Credentials
    }
    
    if (-not (Connect-Infrastructure)) {
        Write-Log "Infrastructure connection failed. Exiting." -Level "ERROR"
        exit 1
    }
    
    # Execute migration steps
    $Datastores = Get-SourceDatastores
    if (-not $Datastores) {
        Write-Log "Failed to discover datastores. Exiting." -Level "ERROR"
        exit 1
    }
    
    $StoppedVMs = Stop-SourceVMs
    $ProcessedVolumes = Update-SnapMirrorRelationships -Datastores $Datastores
    $MountedDatastores = Mount-TargetDatastores -Datastores $Datastores
    $RegisteredVMs = Register-TargetVMs
    $UpdatedVMs = Update-VMNetworkConfiguration
    $StartedVMs = Start-TargetVMs
    $ConfiguredVMs = Set-GuestIPConfiguration
    $TaggedVMs = Add-BackupTags
    $DisconnectedVMs = Disconnect-SourceVMNetworks
    $UnregisteredVMs = Unregister-SourceVMs
    
    Write-MigrationSummary
}
catch {
    Write-Log "Critical error during migration: ${_}" -Level "ERROR"
    Write-MigrationSummary
    exit 1
}
finally {
    Disconnect-Infrastructure
}

#endregion