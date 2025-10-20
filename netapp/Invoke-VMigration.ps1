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

.PARAMETER TargetCluster
    Name of the target vSphere cluster where VMs will be migrated and datastores will be mounted.

.PARAMETER LogPath
    Path where log files will be written. Default is current directory with timestamp.

.PARAMETER BackupTier
    Name of the backup tier tag to apply to migrated VMs. Default is "Tier3".

.PARAMETER WhatIf
    Shows what would be done without making any changes.

.EXAMPLE
    .\Invoke-VMigration.ps1 -CSVPath "C:\VMMigration.csv" -SourcevCenter "vcenter7.domain.com" -TargetvCenter "vcenter8.domain.com" -TargetONTAPCluster "ontap-cluster.domain.com" -TargetNFSSVM "nfs_svm" -TargetCluster "Production-Cluster" -WhatIf

.EXAMPLE
    .\Invoke-VMigration.ps1 -CSVPath "VMs.csv" -SourcevCenter "source-vc.domain.com" -TargetvCenter "target-vc.domain.com" -TargetONTAPCluster "target-ontap.domain.com" -TargetNFSSVM "migration_svm" -TargetCluster "Migration-Cluster"

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
    
    [Parameter(Mandatory = $true)]
    [string]$TargetCluster,
    
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\VMMigration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log",
    
    [Parameter(Mandatory = $false)]
    [string]$BackupTier = "Tier3"
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
        
        # Validate target cluster exists
        Write-Log "Validating target vSphere cluster: ${TargetCluster}" -Level "INFO"
        $TargetClusterObj = Get-Cluster -Server $script:TargetVIServer -Name $TargetCluster -ErrorAction Stop
        $ClusterHosts = Get-VMHost -Location $TargetClusterObj -Server $script:TargetVIServer
        Write-Log "Target cluster '${TargetCluster}' validated successfully ($($ClusterHosts.Count) hosts)" -Level "SUCCESS"
        if ($WhatIf) {
            Write-Log "[WHATIF] Cluster validation complete - ready for migration simulation" -Level "INFO"
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

function Verify-SourceVMsShutdown {
    [CmdletBinding()]
    param()
    
    Write-Log "Step 2: Verifying VMs are powered off in source vCenter..." -Level "INFO"
    
    $VerifiedVMs = @()
    $PoweredOnVMs = @()
    
    foreach ($VM in $script:MigrationData) {
        try {
            $Prefix = if ($WhatIf) { "[WHATIF] " } else { "" }
            $VMObject = Get-VM -Server $script:SourceVIServer -Name $VM.VMName -ErrorAction Stop
            
            if ($VMObject.PowerState -eq "PoweredOff") {
                Write-Log "${Prefix}VM $($VM.VMName) is powered off - ready for migration" -Level "SUCCESS"
                $VerifiedVMs += $VM.VMName
            } else {
                Write-Log "${Prefix}WARNING: VM $($VM.VMName) is still powered on (State: $($VMObject.PowerState))" -Level "ERROR"
                $PoweredOnVMs += $VM.VMName
            }
        }
        catch {
            Write-Log "Failed to check power state of VM $($VM.VMName): ${_}" -Level "ERROR"
        }
    }
    
    if ($PoweredOnVMs.Count -gt 0) {
        Write-Log "ERROR: $($PoweredOnVMs.Count) VMs are still powered on. Please shut down these VMs before proceeding: $($PoweredOnVMs -join ', ')" -Level "ERROR"
        if (-not $WhatIf) {
            throw "Migration cannot continue - VMs must be powered off first"
        }
    }
    
    $LogLevel = if ($WhatIf) { "INFO" } else { "SUCCESS" }
    $Prefix = if ($WhatIf) { "[WHATIF] " } else { "" }
    Write-Log "${Prefix}Verification complete. $($VerifiedVMs.Count) VMs confirmed powered off" -Level $LogLevel
    return $VerifiedVMs
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
            $Prefix = if ($WhatIf) { "[WHATIF] " } else { "" }
            Write-Log "${Prefix}Querying SnapMirror relationships for SVM: ${TargetNFSSVM}" -Level "INFO"
            
            $AllSnapMirrorRelations = Get-NcSnapmirror -DestinationVserver $TargetNFSSVM -ErrorAction Stop
            
            # Filter relationships for this datastore with more precise matching
            $SnapMirrorRelations = @()
            foreach ($Relation in $AllSnapMirrorRelations) {
                # Try exact match first (most reliable)
                if ($Relation.DestinationVolume -eq $DatastoreName) {
                    $SnapMirrorRelations += $Relation
                    break  # Found exact match, stop looking
                }
            }
            
            # If no exact match, try pattern matching but be more restrictive
            if ($SnapMirrorRelations.Count -eq 0) {
                foreach ($Relation in $AllSnapMirrorRelations) {
                    # Only try pattern matching if datastore name is substantial part of volume name
                    if ($Relation.DestinationVolume -like "*$DatastoreName*" -and $DatastoreName.Length -gt 3) {
                        $SnapMirrorRelations += $Relation
                        break  # Take first pattern match to avoid duplicates
                    }
                }
            }
            
            $Prefix = if ($WhatIf) { "[WHATIF] " } else { "" }
            Write-Log "${Prefix}Found $($AllSnapMirrorRelations.Count) total SnapMirror relationships, $($SnapMirrorRelations.Count) matching datastore: ${DatastoreName}" -Level "INFO"
            
            if ($SnapMirrorRelations.Count -eq 0) {
                Write-Log "${Prefix}No SnapMirror relationships found for datastore: ${DatastoreName}" -Level "WARNING"
                Write-Log "${Prefix}Available destination volumes: $($AllSnapMirrorRelations.DestinationVolume -join ', ')" -Level "INFO"
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
            $ErrorMessage = $_.Exception.Message
            $Prefix = if ($WhatIf) { "[WHATIF] " } else { "" }
            Write-Log "${Prefix}Failed to process SnapMirror relationships for datastore ${DatastoreName}" -Level "ERROR"
            Write-Log "${Prefix}Error details: ${ErrorMessage}" -Level "ERROR"
            
            # Continue processing other datastores even if one fails
            continue
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
            $AllVolumes = Get-NcVol -VserverContext $TargetNFSSVM -ErrorAction Stop
            
            # Find matching volume with multiple pattern attempts
            $Volume = $null
            foreach ($Vol in $AllVolumes) {
                # Try exact match first
                if ($Vol.Name -eq $DatastoreName) {
                    $Volume = $Vol
                    break
                }
                # Try pattern matching
                elseif ($Vol.Name -like "*$DatastoreName*") {
                    $Volume = $Vol
                    break
                }
                # Try reverse pattern (datastore name might be part of volume name)
                elseif ($DatastoreName -like "*$($Vol.Name)*") {
                    $Volume = $Vol
                    break
                }
            }
            
            $Prefix = if ($WhatIf) { "[WHATIF] " } else { "" }
            Write-Log "${Prefix}Searched $($AllVolumes.Count) volumes for datastore: ${DatastoreName}" -Level "INFO"
            
            if ($Volume) {
                Write-Log "${Prefix}Found matching volume: $($Volume.Name) for datastore: ${DatastoreName}" -Level "SUCCESS"
                
                $NFSExportPath = "/$($Volume.Name)"
                
                # Get NFS server address with improved interface discovery
                $AllNFSInterfaces = Get-NcNetInterface -VserverContext $TargetNFSSVM -ErrorAction Stop
                $Prefix = if ($WhatIf) { "[WHATIF] " } else { "" }
                
                Write-Log "${Prefix}Found $($AllNFSInterfaces.Count) network interfaces for SVM: ${TargetNFSSVM}" -Level "INFO"
                
                # Try multiple criteria to find NFS interface
                $NFSInterface = $null
                
                # First try: Look for data role with NFS protocol
                $NFSInterface = $AllNFSInterfaces | Where-Object { 
                    $_.Role -eq "data" -and $_.DataProtocols -contains "nfs" 
                } | Select-Object -First 1
                
                # Second try: Look for data role with NFS in protocol list (case variations)
                if (-not $NFSInterface) {
                    $NFSInterface = $AllNFSInterfaces | Where-Object { 
                        $_.Role -eq "data" -and ($_.DataProtocols -match "nfs" -or $_.DataProtocols -match "NFS")
                    } | Select-Object -First 1
                }
                
                # Third try: Look for any interface with NFS (regardless of role)
                if (-not $NFSInterface) {
                    $NFSInterface = $AllNFSInterfaces | Where-Object { 
                        $_.DataProtocols -contains "nfs" -or $_.DataProtocols -match "nfs"
                    } | Select-Object -First 1
                }
                
                # Fourth try: Look for data interfaces (assume NFS capable)
                if (-not $NFSInterface) {
                    $NFSInterface = $AllNFSInterfaces | Where-Object { 
                        $_.Role -eq "data" -and $_.AdminStatus -eq "up"
                    } | Select-Object -First 1
                }
                
                if ($NFSInterface) {
                    $NFSServer = $NFSInterface.Address
                    Write-Log "${Prefix}Selected NFS interface: $($NFSInterface.InterfaceName) ($($NFSInterface.Address)) - Role: $($NFSInterface.Role), Protocols: $($NFSInterface.DataProtocols -join ',')" -Level "SUCCESS"
                    
                    $MountPrefix = if ($WhatIf) { "[WHATIF] Would mount" } else { "Mounting" }
                    Write-Log "${MountPrefix} NFS datastore: ${DatastoreName} from ${NFSServer}:${NFSExportPath}" -Level "INFO"
                    
                    if (-not $WhatIf) {
                        # Get target cluster and its hosts for datastore mounting
                        $Cluster = Get-Cluster -Server $script:TargetVIServer -Name $TargetCluster -ErrorAction Stop
                        $VMHosts = Get-VMHost -Location $Cluster -Server $script:TargetVIServer
                        
                        Write-Log "Mounting datastore on $($VMHosts.Count) hosts in cluster: ${TargetCluster}" -Level "INFO"
                        
                        foreach ($VMHost in $VMHosts) {
                            $NewDatastore = New-Datastore -VMHost $VMHost -Name $DatastoreName -Nfs -NfsHost $NFSServer -Path $NFSExportPath
                            Write-Log "Mounted NFS datastore ${DatastoreName} on host $($VMHost.Name)" -Level "SUCCESS"
                        }
                    } else {
                        # For WhatIf, still validate cluster exists and show host count
                        try {
                            $Cluster = Get-Cluster -Server $script:TargetVIServer -Name $TargetCluster -ErrorAction Stop
                            $VMHosts = Get-VMHost -Location $Cluster -Server $script:TargetVIServer
                            Write-Log "[WHATIF] Would mount datastore on $($VMHosts.Count) hosts in cluster: ${TargetCluster}" -Level "INFO"
                        }
                        catch {
                            Write-Log "[WHATIF] ERROR: Target cluster '${TargetCluster}' not found or inaccessible" -Level "ERROR"
                        }
                    }
                    
                    $MountedDatastores += $DatastoreName
                } else {
                    Write-Log "${Prefix}Could not find suitable NFS interface for SVM: ${TargetNFSSVM}" -Level "ERROR"
                    Write-Log "${Prefix}Available interfaces:" -Level "INFO"
                    foreach ($Interface in $AllNFSInterfaces) {
                        Write-Log "${Prefix}  - $($Interface.InterfaceName): $($Interface.Address) (Role: $($Interface.Role), Protocols: $($Interface.DataProtocols -join ','), Status: $($Interface.AdminStatus))" -Level "INFO"
                    }
                }
            } else {
                Write-Log "${Prefix}Could not find matching volume for datastore: ${DatastoreName}" -Level "ERROR"
                Write-Log "${Prefix}Available volumes: $($AllVolumes.Name -join ', ')" -Level "INFO"
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
            $VMDatastore = $script:VMDatastoreMap[$VM.VMName]
            
            if (-not $WhatIf) {
                # Real registration - verify datastore exists and register VM
                $Datastore = Get-Datastore -Server $script:TargetVIServer -Name $VMDatastore -ErrorAction Stop
                $VMXPath = "[${VMDatastore}] $($VM.VMName)/$($VM.VMName).vmx"
                
                Write-Log "Registering VM: $($VM.VMName) from datastore ${VMDatastore}, path: ${VMXPath}" -Level "INFO"
                
                # Get target cluster and select a host for registration
                $Cluster = Get-Cluster -Server $script:TargetVIServer -Name $TargetCluster -ErrorAction Stop
                $TargetHost = Get-VMHost -Location $Cluster -Server $script:TargetVIServer | Select-Object -First 1
                
                Write-Log "Registering VM to cluster: ${TargetCluster}, host: $($TargetHost.Name)" -Level "INFO"
                
                # Register the VM
                $RegisteredVM = New-VM -VMFilePath $VMXPath -VMHost $TargetHost -Location $Cluster
                
                $RegisteredVMs += $VM.VMName
                Write-Log "Successfully registered VM: $($VM.VMName)" -Level "SUCCESS"
            } else {
                # WhatIf simulation - don't attempt actual operations
                $VMXPath = "[${VMDatastore}] $($VM.VMName)/$($VM.VMName).vmx"
                
                # Simulate cluster and host selection for logging
                try {
                    $Cluster = Get-Cluster -Server $script:TargetVIServer -Name $TargetCluster -ErrorAction Stop
                    $TargetHost = Get-VMHost -Location $Cluster -Server $script:TargetVIServer | Select-Object -First 1
                    
                    Write-Log "[WHATIF] Would register VM: $($VM.VMName) from datastore: ${VMDatastore}" -Level "INFO"
                    Write-Log "[WHATIF] Would use path: ${VMXPath}" -Level "INFO"
                    Write-Log "[WHATIF] Would register to cluster: ${TargetCluster}, host: $($TargetHost.Name)" -Level "INFO"
                    
                    # Simulate successful registration
                    $RegisteredVMs += $VM.VMName
                    Write-Log "[WHATIF] Would successfully register VM: $($VM.VMName)" -Level "SUCCESS"
                }
                catch {
                    Write-Log "[WHATIF] ERROR: Could not validate cluster ${TargetCluster} for VM registration simulation" -Level "ERROR"
                }
            }
        }
        catch {
            if (-not $WhatIf) {
                Write-Log "Failed to register VM $($VM.VMName): ${_}" -Level "ERROR"
            } else {
                Write-Log "[WHATIF] Simulation error for VM $($VM.VMName): ${_}" -Level "WARNING"
            }
        }
    }
    
    Write-Log "Completed VM registration. Successfully registered: $($RegisteredVMs.Count)" -Level "SUCCESS"
    return $RegisteredVMs
}


function Start-TargetVMs {
    [CmdletBinding()]
    param()
    
    Write-Log "Step 6: Powering on VMs in sequential order with individual confirmation..." -Level "INFO"
    
    $StartedVMs = @()
    $VMCount = $script:MigrationData.Count
    $CurrentVM = 0
    
    if (-not $WhatIf) {
        Write-Host "`nVMs will be powered on in the order specified in the CSV file." -ForegroundColor Yellow
        Write-Host "You will be prompted to confirm each VM individually." -ForegroundColor Yellow
        Write-Host "Press Ctrl+C at any time to abort the remaining VM startups.`n" -ForegroundColor Cyan
    }
    
    foreach ($VM in $script:MigrationData) {
        $CurrentVM++
        
        try {
            if (-not $WhatIf) {
                # Real VM startup with individual confirmation
                Write-Host "VM $CurrentVM of ${VMCount}: $($VM.VMName)" -ForegroundColor White -BackgroundColor DarkBlue
                $Confirmation = Read-Host "Power on VM '$($VM.VMName)' now? (y/N/s=skip)"
                
                if ($Confirmation -eq 's' -or $Confirmation -eq 'S') {
                    Write-Log "VM $($VM.VMName) skipped by user" -Level "WARNING"
                    continue
                } elseif ($Confirmation -ne 'y' -and $Confirmation -ne 'Y') {
                    Write-Log "VM startup process cancelled by user at VM: $($VM.VMName)" -Level "WARNING"
                    break
                }
                
                # Attempt to get VM (should exist after registration)
                $VMObject = Get-VM -Server $script:TargetVIServer -Name $VM.VMName -ErrorAction Stop
                
                Write-Log "Powering on VM $CurrentVM of ${VMCount}: $($VM.VMName)" -Level "INFO"
                Start-VM -VM $VMObject -Confirm:$false | Out-Null
                
                # Wait for VM to start and check for questions
                Write-Host "  Waiting for VM to start..." -ForegroundColor Gray
                Start-Sleep -Seconds 30
                
                # Check for and answer VM questions (I moved it)
                $VMView = Get-View -VIObject $VMObject
                if ($VMView.Runtime.Question) {
                    Write-Log "Answering VM question for $($VM.VMName): I moved it" -Level "INFO"
                    Write-Host "  Answering relocation question..." -ForegroundColor Gray
                    $VMView.AnswerVM($VMView.Runtime.Question.Id, "0") # "0" typically means "I moved it"
                }
                
                # Allow VM to complete startup
                Write-Host "  Allowing VM to complete startup..." -ForegroundColor Gray
                Start-Sleep -Seconds 15
                
                # Verify VM is running
                $VMObject = Get-VM -Server $script:TargetVIServer -Name $VM.VMName
                if ($VMObject.PowerState -eq "PoweredOn") {
                    Write-Host "  VM $($VM.VMName) started successfully" -ForegroundColor Green
                    $StartedVMs += $VM.VMName  
                    Write-Log "Successfully started VM $CurrentVM of ${VMCount}: $($VM.VMName)" -Level "SUCCESS"
                } else {
                    Write-Host "  WARNING: VM $($VM.VMName) may not have started properly (State: $($VMObject.PowerState))" -ForegroundColor Red
                    Write-Log "VM $($VM.VMName) startup completed but state is: $($VMObject.PowerState)" -Level "WARNING"
                }
                
                # Brief pause before next VM
                if ($CurrentVM -lt $VMCount) {
                    Write-Host "  Brief pause before next VM...`n" -ForegroundColor Gray
                    Start-Sleep -Seconds 5
                }
                
            } else {
                # WhatIf simulation - don't attempt VM operations
                Write-Log "[WHATIF] Would prompt to power on VM $CurrentVM of ${VMCount}: $($VM.VMName)" -Level "INFO"
                Write-Log "[WHATIF] Would wait for VM startup and check for relocation questions" -Level "INFO"
                Write-Log "[WHATIF] Would answer relocation question with 'I moved it' if prompted" -Level "INFO"
                Write-Log "[WHATIF] Would verify VM reaches PoweredOn state" -Level "INFO"
                
                # Simulate successful startup
                $StartedVMs += $VM.VMName
                Write-Log "[WHATIF] Would successfully start VM $CurrentVM of ${VMCount}: $($VM.VMName)" -Level "SUCCESS"
            }
        }
        catch {
            Write-Log "Failed to start VM $($VM.VMName): ${_}" -Level "ERROR"
            Write-Host "  ERROR: Failed to start VM $($VM.VMName)" -ForegroundColor Red
            
            if (-not $WhatIf) {
                $ContinueOnError = Read-Host "Continue with remaining VMs? (y/N)"
                if ($ContinueOnError -ne 'y' -and $ContinueOnError -ne 'Y') {
                    Write-Log "VM startup process aborted after error with $($VM.VMName)" -Level "ERROR"
                    break
                }
            }
        }
    }
    
    $LogLevel = if ($WhatIf) { "INFO" } else { "SUCCESS" }
    Write-Log "VM startup process completed. Successfully started: $($StartedVMs.Count) of $VMCount VMs" -Level $LogLevel
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
                    # Real tagging - get VM and apply tag
                    $VMObject = Get-VM -Server $script:TargetVIServer -Name $VM.VMName -ErrorAction Stop
                    New-TagAssignment -Tag $BackupTag -Entity $VMObject | Out-Null
                    
                    $TaggedVMs += $VM.VMName
                    Write-Log "Applied backup tag '${BackupTier}' to VM: $($VM.VMName)" -Level "SUCCESS"
                } else {
                    # WhatIf simulation - don't attempt VM operations
                    Write-Log "[WHATIF] Would create backup tag category 'Backup' if needed" -Level "INFO"
                    Write-Log "[WHATIF] Would create backup tag '${BackupTier}' if needed" -Level "INFO"
                    Write-Log "[WHATIF] Would apply backup tag '${BackupTier}' to VM: $($VM.VMName)" -Level "INFO"
                    
                    # Simulate successful tagging
                    $TaggedVMs += $VM.VMName
                    Write-Log "[WHATIF] Would successfully tag VM: $($VM.VMName)" -Level "SUCCESS"
                }
            }
            catch {
                if (-not $WhatIf) {
                    Write-Log "Failed to tag VM $($VM.VMName): ${_}" -Level "ERROR"
                } else {
                    Write-Log "[WHATIF] Simulation warning for VM tagging $($VM.VMName): ${_}" -Level "WARNING"
                }
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
    
    Write-Log ("`n" + "="*80) -Level "INFO"
    Write-Log "VM MIGRATION SUMMARY" -Level "INFO" 
    Write-Log ("="*80) -Level "INFO"
    Write-Log "Total VMs to migrate: ${TotalVMs}" -Level "INFO"
    Write-Log "Errors encountered: $($script:ErrorCount)" -Level "INFO"
    Write-Log "Warnings encountered: $($script:WarningCount)" -Level "INFO"
    Write-Log "Log file location: $($script:LogFile)" -Level "INFO"
    Write-Log "Migration completed at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level "INFO"
    Write-Log ("="*80) -Level "INFO"
    
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
Write-Log "Target vSphere Cluster: ${TargetCluster}" -Level "INFO"
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
    
    $VerifiedVMs = Verify-SourceVMsShutdown
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