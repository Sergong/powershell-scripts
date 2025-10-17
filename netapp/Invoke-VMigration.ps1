<#
.SYNOPSIS
    Migrates VMs from source vSphere 7 environment to target vSphere 8 environment with NetApp ONTAP backing.
    VMs retain their existing IP addresses during migration.

.DESCRIPTION
    This script automates the migration of VMs from a source vSphere environment to a target vSphere environment.
    Both environments are backed by NetApp ONTAP clusters with NFS datastores. The script handles the complete
    migration workflow including VM discovery, power operations, SnapMirror operations, datastore mounting,
    VM registration, backup tagging, and cleanup operations.
    
    The script automatically discovers which datastore each VM is located on and uses the same datastore name
    on the target environment. VMs retain their existing network configuration during migration.

.PARAMETER CSVPath
    Path to the CSV file containing VM migration information.
    Required columns: VMName

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

.PARAMETER WhatIf
    Shows what would be done without making any changes.

.EXAMPLE
    .\Invoke-VMigration.ps1 -CSVPath "C:\VMMigration.csv" -SourcevCenter "vcenter7.domain.com" -TargetvCenter "vcenter8.domain.com" -TargetONTAPCluster "ontap-cluster.domain.com" -TargetNFSSVM "nfs_svm" -WhatIf

.EXAMPLE
    .\Invoke-VMigration.ps1 -CSVPath "VMs.csv" -SourcevCenter "source-vc.domain.com" -TargetvCenter "target-vc.domain.com" -TargetONTAPCluster "target-ontap.domain.com" -TargetNFSSVM "migration_svm"

.NOTES
    Author: PowerShell Automation
    Version: 2.0
    Requires: VMware.PowerCLI, NetApp.ONTAP modules
    
    This script requires administrative privileges and proper credentials for:
    - Source vCenter Server
    - Target vCenter Server  
    - Target NetApp ONTAP Cluster
    
    VMs retain their existing IP addresses and network configuration during migration.
    Datastores are automatically discovered and mounted with matching names on the target cluster.
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
    
    [switch]$WhatIf
)

# Global Variables
$script:LogFile = $LogPath
$script:MigrationData = @()
$script:VMDatastoreMap = @{}
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
        $RequiredColumns = @('VMName')
        
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
    
    Write-Log "Credentials collected successfully" -Level "SUCCESS"
}

function Connect-Infrastructure {
    [CmdletBinding()]
    param()
    
    Write-Log "Connecting to infrastructure components..." -Level "INFO"
    
    try {
        # Connect to Source vCenter (always connect for discovery)
        Write-Log "Connecting to Source vCenter: ${SourcevCenter}" -Level "INFO"
        $script:SourceVIServer = Connect-VIServer -Server $SourcevCenter -Credential $script:SourcevCenterCredentials -ErrorAction Stop
        Write-Log "Successfully connected to Source vCenter" -Level "SUCCESS"
        if ($WhatIf) {
            Write-Log "[WHATIF] Connected for discovery only - no changes will be made to source environment" -Level "INFO"
        }
        
        # Connect to Target vCenter (always connect for discovery)
        Write-Log "Connecting to Target vCenter: ${TargetvCenter}" -Level "INFO" 
        $script:TargetVIServer = Connect-VIServer -Server $TargetvCenter -Credential $script:TargetvCenterCredentials -ErrorAction Stop
        Write-Log "Successfully connected to Target vCenter" -Level "SUCCESS"
        if ($WhatIf) {
            Write-Log "[WHATIF] Connected for discovery only - no changes will be made to target environment" -Level "INFO"
        }
        
        # Connect to ONTAP Cluster (always connect for discovery)
        Write-Log "Connecting to ONTAP Cluster: ${TargetONTAPCluster}" -Level "INFO"
        $script:ONTAPConnection = Connect-NcController -Name $TargetONTAPCluster -Credential $script:ONTAPCredentials -ErrorAction Stop
        Write-Log "Successfully connected to ONTAP Cluster" -Level "SUCCESS"
        if ($WhatIf) {
            Write-Log "[WHATIF] Connected for discovery only - no changes will be made to ONTAP cluster" -Level "INFO"
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
    
    Write-Log "Step 1: Discovering VMs and their NFS Datastores..." -Level "INFO"
    
    $DiscoveredDatastores = @{}
    $VMDatastoreMap = @{}
    
    foreach ($VMData in $script:MigrationData) {
        try {
            # Always perform discovery (read-only operation)
            $VMObject = Get-VM -Server $script:SourceVIServer -Name $VMData.VMName -ErrorAction Stop
            $VMDatastore = Get-Datastore -VM $VMObject | Select-Object -First 1
            
            # Store VM to datastore mapping
            $VMDatastoreMap[$VMData.VMName] = $VMDatastore.Name
            
            # Add datastore to discovery list if not already present
            if ($VMDatastore.Name -notin $DiscoveredDatastores.Keys) {
                $DiscoveredDatastores[$VMDatastore.Name] = $VMDatastore
                $LogLevel = if ($WhatIf) { "INFO" } else { "SUCCESS" }
                $Prefix = if ($WhatIf) { "[WHATIF] " } else { "" }
                Write-Log "${Prefix}Discovered datastore: $($VMDatastore.Name) (Type: $($VMDatastore.Type), Capacity: $([math]::Round($VMDatastore.CapacityGB, 2)) GB)" -Level $LogLevel
            }
            
            $Prefix = if ($WhatIf) { "[WHATIF] " } else { "" }
            Write-Log "${Prefix}VM $($VMData.VMName) is located on datastore: $($VMDatastore.Name)" -Level "INFO"
        }
        catch {
            Write-Log "Failed to find VM $($VMData.VMName) or its datastore: ${_}" -Level "ERROR"
            return $null
        }
    }
    
    # Store the VM-to-datastore mapping for use by other functions
    $script:VMDatastoreMap = $VMDatastoreMap
    
    $Prefix = if ($WhatIf) { "[WHATIF] " } else { "" }
    $LogLevel = if ($WhatIf) { "INFO" } else { "SUCCESS" }
    Write-Log "${Prefix}Successfully discovered $($DiscoveredDatastores.Count) unique datastores for $($script:MigrationData.Count) VMs" -Level $LogLevel
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
            # Always discover SnapMirror relationships (read-only operation)
            $SnapMirrorRelations = Get-NcSnapmirror -DestinationVserver $TargetNFSSVM | Where-Object { 
                $_.DestinationVolume -like "*$DatastoreName*" 
            }
            
            if ($SnapMirrorRelations.Count -eq 0) {
                $Prefix = if ($WhatIf) { "[WHATIF] " } else { "" }
                Write-Log "${Prefix}No SnapMirror relationships found for datastore: ${DatastoreName}" -Level "WARNING"
                continue
            }
            
            foreach ($Relation in $SnapMirrorRelations) {
                $Prefix = if ($WhatIf) { "[WHATIF] Would process" } else { "Processing" }
                Write-Log "${Prefix} SnapMirror relationship: $($Relation.SourcePath) -> $($Relation.DestinationPath)" -Level "INFO"
                
                if (-not $WhatIf) {
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
                    
                    Write-Log "Successfully processed SnapMirror relationship for volume: $($Relation.DestinationVolume)" -Level "SUCCESS"
                } else {
                    Write-Log "[WHATIF] Would update/quiesce/break SnapMirror relationship for volume: $($Relation.DestinationVolume)" -Level "INFO"
                }
                
                $ProcessedVolumes += $Relation.DestinationVolume
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
            # Always discover volumes and NFS servers (read-only operations)
            $Volume = Get-NcVol -VserverContext $TargetNFSSVM | Where-Object { 
                $_.Name -like "*$DatastoreName*" 
            } | Select-Object -First 1
            
            if ($Volume) {
                $NFSExportPath = "/$($Volume.Name)"
                $NFSServer = (Get-NcNetInterface -VserverContext $TargetNFSSVM | Where-Object { 
                    $_.Role -eq "data" -and $_.DataProtocols -contains "nfs" 
                } | Select-Object -First 1).Address
                
                $Prefix = if ($WhatIf) { "[WHATIF] Would mount" } else { "Mounting" }
                Write-Log "${Prefix} NFS datastore: ${DatastoreName} from ${NFSServer}:${NFSExportPath}" -Level "INFO"
                
                if (-not $WhatIf) {
                    # Get target cluster hosts and mount datastores (write operations)
                    $VMHosts = Get-VMHost -Server $script:TargetVIServer
                    foreach ($VMHost in $VMHosts) {
                        $NewDatastore = New-Datastore -VMHost $VMHost -Name $DatastoreName -Nfs -NfsHost $NFSServer -Path $NFSExportPath
                        Write-Log "Mounted NFS datastore ${DatastoreName} on host $($VMHost.Name)" -Level "SUCCESS"
                    }
                }
                
                $MountedDatastores += $DatastoreName
            } else {
                $Prefix = if ($WhatIf) { "[WHATIF] " } else { "" }
                Write-Log "${Prefix}Could not find matching volume for datastore: ${DatastoreName}" -Level "ERROR"
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
    
    # Prompt for confirmation before registering VMs
    if (-not $WhatIf) {
        Write-Host "`nReady to register $($script:MigrationData.Count) VMs in target vCenter." -ForegroundColor Yellow
        Write-Host "This will make the VMs visible in the target environment but they will remain powered off." -ForegroundColor Yellow
        $Confirmation = Read-Host "Continue with VM registration? (y/N)"
        if ($Confirmation -ne 'y' -and $Confirmation -ne 'Y') {
            Write-Log "VM registration cancelled by user" -Level "WARNING"
            return @()
        }
        Write-Log "User confirmed VM registration. Proceeding..." -Level "INFO"
    }
    
    $RegisteredVMs = @()
    
    foreach ($VM in $script:MigrationData) {
        try {
            if (-not $WhatIf) {
                # Get the discovered datastore for this VM
                $VMDatastore = $script:VMDatastoreMap[$VM.VMName]
                $Datastore = Get-Datastore -Server $script:TargetVIServer -Name $VMDatastore -ErrorAction Stop
                $VMXPath = "[${VMDatastore}] $($VM.VMName)/$($VM.VMName).vmx"
                
                Write-Log "Registering VM: $($VM.VMName) from datastore ${VMDatastore}, path: ${VMXPath}" -Level "INFO"
                
                # Get a target host for registration
                $TargetHost = Get-VMHost -Server $script:TargetVIServer | Select-Object -First 1
                
                # Register the VM
                $RegisteredVM = New-VM -VMFilePath $VMXPath -VMHost $TargetHost -Location (Get-Folder -Server $script:TargetVIServer -Name "vm")
                
                $RegisteredVMs += $VM.VMName
                Write-Log "Successfully registered VM: $($VM.VMName)" -Level "SUCCESS"
            } else {
                $VMDatastore = $script:VMDatastoreMap[$VM.VMName]
                Write-Log "[WHATIF] Would register VM: $($VM.VMName) from datastore: ${VMDatastore}" -Level "INFO"
            }
        }
        catch {
            Write-Log "Failed to register VM $($VM.VMName): ${_}" -Level "ERROR"
        }
    }
    
    Write-Log "Completed VM registration. Successfully registered: $($RegisteredVMs.Count)" -Level "SUCCESS"
    return $RegisteredVMs
}


function Start-TargetVMs {
    [CmdletBinding()]
    param()
    
    Write-Log "Step 6: Powering on VMs and answering relocation questions..." -Level "INFO"
    
    # Prompt for confirmation before starting VMs
    if (-not $WhatIf) {
        Write-Host "`nReady to power on $($script:MigrationData.Count) VMs in target environment." -ForegroundColor Yellow
        Write-Host "This will start the VMs and make them active on the target cluster." -ForegroundColor Yellow
        Write-Host "WARNING: This is the point of no return - VMs will be running on the target environment." -ForegroundColor Red
        $Confirmation = Read-Host "Continue with powering on VMs? (y/N)"
        if ($Confirmation -ne 'y' -and $Confirmation -ne 'Y') {
            Write-Log "VM startup cancelled by user" -Level "WARNING"
            return @()
        }
        Write-Log "User confirmed VM startup. Proceeding with power on operations..." -Level "INFO"
    }
    
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
                
                # Allow VM to complete startup
                Start-Sleep -Seconds 15
                
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


function Add-BackupTags {
    [CmdletBinding()]
    param()
    
    Write-Log "Step 7: Adding backup tags to VMs..." -Level "INFO"
    
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
    
    Write-Log "Step 8: Disconnecting source VM network adapters..." -Level "INFO"
    
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
    
    Write-Log "Step 9: Unregistering VMs from source vCenter..." -Level "INFO"
    
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
    
    # Always collect credentials (needed for connections even in WhatIf mode)
    Get-Credentials
    
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
    $StartedVMs = Start-TargetVMs
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