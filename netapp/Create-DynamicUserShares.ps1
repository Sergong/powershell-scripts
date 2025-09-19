<#
.SYNOPSIS
    Creates dynamic home directories in ONTAP using %w for both share name and path
.DESCRIPTION
    Automates creation of dynamic home directories where users access \\server\username
    The %w variable automatically resolves to the user's Windows username for both share name and path
.PARAMETER ClusterName
    ONTAP cluster management LIF or name
.PARAMETER SVMName
    Storage Virtual Machine name
.PARAMETER VolumeName
    Volume name for home directories
.PARAMETER AggregateName
    Aggregate to create volume on
.PARAMETER VolumeSize
    Size of the home directory volume
.PARAMETER Domain
    Active Directory domain name
.PARAMETER UserList
    Array of usernames to create home directories for
.PARAMETER UserQuota
    Individual user quota limit
.PARAMETER UserSoftQuota
    Individual user soft quota limit
.PARAMETER AllUsersPath
    Relative Path on the volume where user dirs will be created
.PARAMETER DynamicShareName
    The dynamic share to be created (usually %w)
.PARAMETER HomeDriveLetter
    The Home Drive Letter to be used for the AD User configuration
.PARAMETER SkipADIntegration
    Skip Active Directory integration and home directory configuration

.EXAMPLE
    .\Create-DynamicHomeDirectories.ps1 -ClusterName "cluster1.company.com" -SVMName "svm_cifs" -VolumeName "user_homes" -AggregateName "aggr1" -VolumeSize "10GB" -Domain "COMPANY" -AllUsersPath "users" -UserList @("jsmith","bmiller","sthomas") -UserQuota "2GB" -UserSoftQuota "2GB"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterName,
    
    [Parameter(Mandatory=$true)]
    [string]$SVMName,
    
    [Parameter(Mandatory=$true)]
    [string]$VolumeName,
    
    [Parameter(Mandatory=$true)]
    [string]$AggregateName,
    
    [Parameter(Mandatory=$true)]
    [string]$VolumeSize,
    
    [Parameter(Mandatory=$true)]
    [string]$Domain,
    
    [Parameter(Mandatory=$true)]
    [string[]]$UserList,
    
    [Parameter(Mandatory=$false)]
    [string]$UserQuota = "",
    
    [Parameter(Mandatory=$false)]
    [string]$UserSoftQuota = "",

    [Parameter(Mandatory=$false)]
    [string]$AllUsersPath = "users",

    [Parameter(Mandatory=$false)]
    [string]$DynamicShareName = "%w",

    [Parameter(Mandatory=$false)]
    [string]$HomeDriveLetter = "H",

    [Parameter(Mandatory=$false)]
    [switch]$SkipADIntegration
)

#Requires -Modules DataONTAP

# Import NetApp ONTAP PowerShell Toolkit
Import-Module DataONTAP -ErrorAction Stop

# Function to test and import ActiveDirectory module
function Import-ActiveDirectoryModule {
    param(
        [switch]$Force
    )
    
    try {
        # Check if ActiveDirectory module is available
        if (Get-Module -ListAvailable -Name ActiveDirectory) {
            Write-Log "ActiveDirectory module found, importing..."
            Import-Module ActiveDirectory -Force:$Force -ErrorAction Stop
            Write-Log "ActiveDirectory module imported successfully" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "ActiveDirectory module not available on this system" -Level "WARNING"
            Write-Log "Install RSAT (Remote Server Administration Tools) to enable AD integration" -Level "WARNING"
            return $false
        }
    } catch {
        Write-Log "Failed to import ActiveDirectory module: $($_.Exception.Message)" -Level "WARNING"
        return $false
    }
}

# Function to manually configure home directory search path (for troubleshooting)
function Set-HomeDirSearchPath {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SearchPath,
        
        [Parameter(Mandatory=$true)]
        [string]$SVMName,
        
        [Parameter(Mandatory=$false)]
        [switch]$Force
    )
    
    Write-Log "Manual search path configuration requested"
    Write-Log "Search Path: $SearchPath"
    Write-Log "SVM: $SVMName"
    
    try {
        # Check current search paths
        $ExistingPaths = Get-NcCifsHomeDirSearchPath -Vserver $SVMName -ErrorAction SilentlyContinue
        $PathExists = $ExistingPaths | Where-Object { $_.Path -eq $SearchPath }
        
        if ($PathExists -and -not $Force) {
            Write-Log "Search path already exists: $SearchPath" -Level "WARNING"
            Write-Log "Use -Force to reconfigure if needed" -Level "INFO"
            return $true
        }
        
        # Add or update the search path
        Add-NcCifsHomeDirSearchPath -Path $SearchPath -Vserver $SVMName -ErrorAction Stop
        Write-Log "Search path configured successfully: $SearchPath" -Level "SUCCESS"
        
        # Verify
        Start-Sleep -Seconds 2  # Brief pause for ONTAP to process
        $VerifyPaths = Get-NcCifsHomeDirSearchPath -Vserver $SVMName -ErrorAction Stop
        $NewPath = $VerifyPaths | Where-Object { $_.Path -eq $SearchPath }
        
        if ($NewPath) {
            Write-Log "Verification successful: Search path is active" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Verification failed: Search path may not be active" -Level "ERROR"
            return $false
        }
        
    } catch {
        Write-Log "Failed to configure search path: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# Function to log output with timestamp
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $(
        switch($Level) {
            "ERROR" { "Red" }
            "WARNING" { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
    )
}


$JunctionPath = "/$VolumeName"
$SearchPath = "/$VolumeName/$AllUsersPath"
# For ONTAP dynamic home directory shares, use %w and set homedirectory at creation time
$SharePath = "%w"

try {
    # Connect to ONTAP Cluster
    Write-Log "Connecting to ONTAP cluster: $ClusterName"
    $Credential = Get-Credential -Message "Enter ONTAP cluster credentials"
    $Controller = Connect-NcController -Name $ClusterName -Credential $Credential -ErrorAction Stop
    Write-Log "Successfully connected to cluster: $ClusterName" -Level "SUCCESS"

    # Verify SVM exists and CIFS is configured
    Write-Log "Verifying SVM: $SVMName"
    $SVM = Get-NcVserver -Name $SVMName -ErrorAction SilentlyContinue
    if (-not $SVM) {
        Write-Log "SVM $SVMName not found!" -Level "ERROR"
        exit 1
    }
    
    # Check CIFS server status
    $CIFSServer = Get-NcCifsServer -VserverContext $SVMName -ErrorAction SilentlyContinue
    if (-not $CIFSServer) {
        Write-Log "CIFS server not configured on SVM $SVMName!" -Level "ERROR"
        exit 1
    }
    Write-Log "SVM $SVMName and CIFS server verified" -Level "SUCCESS"

    # Create Home Directory Volume
    Write-Log "Creating volume: $VolumeName"
    $ExistingVolume = Get-NcVol -Name $VolumeName -VserverContext $SVMName -ErrorAction SilentlyContinue
    if (-not $ExistingVolume) {
        $VolumeParams = @{
            Name = $VolumeName
            Aggregate = $AggregateName
            Size = $VolumeSize
            JunctionPath = $JunctionPath
            SecurityStyle = "ntfs"
            VserverContext = $SVMName
        }
        New-NcVol @VolumeParams -ErrorAction Stop
        Write-Log "Volume $VolumeName created successfully" -Level "SUCCESS"
    } else {
        Write-Log "Volume $VolumeName already exists" -Level "WARNING"
    }

    # Create administrative share for directory creation
    Write-Log "Creating administrative share for setup"
    $AdminShareName = "$VolumeName$"
    $ExistingAdminShare = Get-NcCifsShare -Name $AdminShareName -Vserver $SVMName -ErrorAction SilentlyContinue
    if (-not $ExistingAdminShare) {
        $AdminShareParams = @{
            Name = $AdminShareName
            Path = $JunctionPath
            Vserver = $SVMName
        }
        Add-NcCifsShare @AdminShareParams -ErrorAction Stop
        Write-Log "Administrative share $AdminShareName created" -Level "SUCCESS"
    } else {
        Write-Log "Administrative share $AdminShareName already exists" -Level "WARNING"
    }

    # Create user directories directly under the volume root
    Write-Log "Creating user directories under volume root"
    $ShareUNC = "\\$($CIFSServer.CifsServer)\$AdminShareName"
    $TempDrive = "Z:"
    
    try {
        net use $TempDrive $ShareUNC /persistent:no | Out-Null
        Write-Log "Mapped administrative share to $TempDrive" -Level "SUCCESS"
        
        # Create individual user directories directly under volume root
        foreach ($username in $UserList) {
            $userPath = "$TempDrive\$AllUsersPath\$username"
            if (-not (Test-Path $userPath)) {
                New-Item -Path $userPath -ItemType Directory -Force | Out-Null
                Write-Log "Created user directory: $username" -Level "SUCCESS"
            } else {
                Write-Log "User directory already exists: $username" -Level "WARNING"
            }
        }
    } finally {
        # Disconnect mapped drive
        net use $TempDrive /delete /y 2>$null | Out-Null
    }

    # Create Dynamic Home Directory Share with %w as share name
    Write-Log "Creating dynamic home directory share: $DynamicShareName"
    $ExistingDynamicShare = Get-NcCifsShare -Name $DynamicShareName -Vserver $SVMName -ErrorAction SilentlyContinue
    if (-not $ExistingDynamicShare) {
        # Ensure 'homedirectory' property is set at creation time so ONTAP accepts non-absolute %w path
        $ShareProperties = @("homedirectory", "oplocks", "browsable", "changenotify")
        $DynamicShareParams = @{
            Name = $DynamicShareName  # %w
            Path = $SharePath         # %w
            ShareProperties = $ShareProperties
            Vserver = $SVMName
            ErrorAction = 'Stop'
        }
        Add-NcCifsShare @DynamicShareParams
        
        Write-Log "Dynamic home directory share '$DynamicShareName' created with path '$SharePath' and homedirectory property" -Level "SUCCESS"
    } else {
        Write-Log "Dynamic home directory share $DynamicShareName already exists" -Level "WARNING"
    }

    # Configure Home Directory Search Path
    Write-Log "Configuring home directory search path: $SearchPath"
    
    # First check if search path already exists
    $ExistingSearchPaths = Get-NcCifsHomeDirSearchPath -Vserver $SVMName -ErrorAction SilentlyContinue
    $SearchPathExists = $ExistingSearchPaths | Where-Object { $_.Path -eq $SearchPath }
    
    if ($SearchPathExists) {
        Write-Log "Home directory search path already exists: $SearchPath" -Level "WARNING"
    } else {
        try {
            $SearchPathParams = @{
                Path = $SearchPath
                Vserver = $SVMName
                ErrorAction = 'Stop'
            }
            Add-NcCifsHomeDirSearchPath @SearchPathParams
            Write-Log "Home directory search path configured: $SearchPath" -Level "SUCCESS"
            
            # Verify the search path was added
            $VerifySearchPaths = Get-NcCifsHomeDirSearchPath -Vserver $SVMName -ErrorAction SilentlyContinue
            $NewSearchPath = $VerifySearchPaths | Where-Object { $_.Path -eq $SearchPath }
            if ($NewSearchPath) {
                Write-Log "Verified search path was added successfully: $SearchPath" -Level "SUCCESS"
            } else {
                Write-Log "WARNING: Search path may not have been added properly. Manual verification needed." -Level "WARNING"
            }
        } catch {
            Write-Log "Failed to add home directory search path: $($_.Exception.Message)" -Level "ERROR"
            Write-Log "This may prevent dynamic home directory functionality from working properly" -Level "ERROR"
            
            # Provide troubleshooting information
            Write-Host "`nTroubleshooting Information:" -ForegroundColor Yellow
            Write-Host "Search Path: $SearchPath" -ForegroundColor White
            Write-Host "SVM: $SVMName" -ForegroundColor White
            Write-Host "Manual command to add search path:" -ForegroundColor Yellow
            Write-Host "Add-NcCifsHomeDirSearchPath -Path '$SearchPath' -Vserver '$SVMName'" -ForegroundColor Gray
        }
    }
    
    # Always show current search paths for verification
    Write-Log "Current home directory search paths:"
    try {
        $CurrentSearchPaths = Get-NcCifsHomeDirSearchPath -Vserver $SVMName -ErrorAction Stop
        if ($CurrentSearchPaths) {
            foreach ($path in $CurrentSearchPaths) {
                Write-Log "  Search Path: $($path.Path)" -Level "INFO"
            }
        } else {
            Write-Log "  No search paths currently configured!" -Level "WARNING"
        }
    } catch {
        Write-Log "Unable to retrieve current search paths: $($_.Exception.Message)" -Level "ERROR"
    }

    # Configure User Quotas (only if quotas are specified)
    if ($UserQuota -and $UserQuota -ne "" -and $UserQuota -ne "0" -and $UserQuota -ne "0GB") {
        Write-Log "Configuring user quotas"
        foreach ($username in $UserList) {
            $domainUser = "$Domain\$username"
            Write-Log "Setting quota for user: $domainUser"
            
            $UserQuotaParams = @{
                Volume = $VolumeName
                Target = $domainUser
                DiskLimit = $UserQuota
                SoftDiskLimit = $UserSoftQuota
                Type = "user"
                Vserver = $SVMName
            }
            
            try {
                Add-NcQuota @UserQuotaParams -ErrorAction Stop
                Write-Log "Quota set for $domainUser" -Level "SUCCESS"
            } catch {
                Write-Log "Failed to set quota for ${domainUser}: $($_.Exception.Message)" -Level "WARNING"
            }
        }

        # Enable Quotas on Volume (only if quotas were configured)
        Write-Log "Enabling quotas on volume $VolumeName"
        try {
            $EnableQuotaParams = @{
                Volume = $VolumeName
                Vserver = $SVMName
                ErrorAction = 'Stop'
            }
            Enable-NcQuota @EnableQuotaParams
            Write-Log "Quotas enabled on volume $VolumeName" -Level "SUCCESS"
        } catch {
            Write-Log "Failed to enable quotas: $($_.Exception.Message)" -Level "WARNING"
        }
    } else {
        Write-Log "No user quotas specified - skipping quota configuration" -Level "WARNING"
    }



    # Set NTFS Permissions
    Write-Log "Configuring NTFS permissions for user directories"
    
    # Re-map for permissions configuration
    net use $TempDrive $ShareUNC /persistent:no | Out-Null
    
    try {
        # Set restrictive permissions on volume root
        Write-Log "Setting volume root permissions (restrictive access)"
        
        $rootAcl = Get-Acl -Path $TempDrive
        $rootAcl.SetAccessRuleProtection($true, $false)
        
        # Add System and Administrators with full control
        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        
        # Add Domain Users with traverse permissions only (to reach their own directory)
        $traverseRule = New-Object System.Security.AccessControl.FileSystemAccessRule("$Domain\Domain Users", "Traverse", "None", "None", "Allow")
        
        $rootAcl.AddAccessRule($systemRule)
        $rootAcl.AddAccessRule($adminRule)
        $rootAcl.AddAccessRule($traverseRule)
        
        Set-Acl -Path $TempDrive -AclObject $rootAcl
        Write-Log "Volume root permissions configured" -Level "SUCCESS"
        
        # Set individual user directory permissions
        foreach ($username in $UserList) {
            $userPath = "$TempDrive\\$AllUsersPath\\$username"
            $domainUser = "$Domain\$username"
            
            Write-Log "Setting permissions for $domainUser"
            
            $userAcl = Get-Acl -Path $userPath
            $userAcl.SetAccessRuleProtection($true, $false)
            
            # Add System, Administrators, and the specific user
            $userSystemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
            $userAdminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
            $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule($domainUser, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
            
            $userAcl.AddAccessRule($userSystemRule)
            $userAcl.AddAccessRule($userAdminRule)
            $userAcl.AddAccessRule($userRule)
            
            Set-Acl -Path $userPath -AclObject $userAcl
            Write-Log "Permissions set for $domainUser" -Level "SUCCESS"
        }
    } finally {
        # Disconnect mapped drive
        net use $TempDrive /delete /y 2>$null | Out-Null
    }

    # Configure Active Directory User Profiles
    if ($SkipADIntegration) {
        Write-Log "Skipping Active Directory integration (SkipADIntegration specified)" -Level "WARNING"
    } else {
        Write-Log "Configuring Active Directory user profiles"
        $ADModuleAvailable = Import-ActiveDirectoryModule
    
    if ($ADModuleAvailable) {
        Write-Log "Proceeding with automatic AD user profile configuration"
        
        foreach ($username in $UserList) {
            # With %w share name, users access \\server\username directly
            $homePath = "\\$($CIFSServer.CifsServer)\$username"
            
            try {
                # Verify user exists in AD before setting home directory
                $ADUser = Get-ADUser -Identity $username -ErrorAction Stop
                Write-Log "Found AD user: $username ($($ADUser.Name))"
                
                $ADUserParams = @{
                    Identity = $username
                    HomeDrive = "${HomeDriveLetter}:"
                    HomeDirectory = $homePath
                    ErrorAction = 'Stop'
                }
                Set-ADUser @ADUserParams
                Write-Log "AD home directory set for ${username}: $homePath" -Level "SUCCESS"
            } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
                Write-Log "User $username not found in Active Directory" -Level "WARNING"
            } catch {
                Write-Log "Failed to set AD home directory for ${username}: $($_.Exception.Message)" -Level "WARNING"
            }
        }
    } else {
        Write-Log "ActiveDirectory module not available. Manual AD configuration required." -Level "WARNING"
        Write-Host "`nManual AD Configuration Required:" -ForegroundColor Yellow
        Write-Host "To enable automatic AD integration, install one of the following:" -ForegroundColor Yellow
        Write-Host "  • Windows: Install RSAT (Remote Server Administration Tools)" -ForegroundColor White
        Write-Host "  • Windows Server: Add 'AD DS and AD LDS Tools' feature" -ForegroundColor White
        Write-Host "  • PowerShell Core: Install ActiveDirectory module from PowerShell Gallery" -ForegroundColor White
        Write-Host "`nManual steps to configure home directories:" -ForegroundColor Yellow
        foreach ($username in $UserList) {
            Write-Host "  Set $username home directory to: \\$($CIFSServer.CifsServer)\$username" -ForegroundColor White
        }
        Write-Host "`nPowerShell commands for manual configuration:" -ForegroundColor Yellow
        foreach ($username in $UserList) {
            Write-Host "  Set-ADUser -Identity '$username' -HomeDrive '${HomeDriveLetter}:' -HomeDirectory '\\$($CIFSServer.CifsServer)\$username'" -ForegroundColor Gray
        }
    }
    }

    # Create Snapshot Policy
    # Write-Log "Creating snapshot policy for home directories"
    # try {
    #     $SnapshotPolicy = "home_dir_policy"
    #     $ExistingPolicy = Get-NcSnapshotPolicy -Name $SnapshotPolicy -Vserver $SVMName -ErrorAction SilentlyContinue
        
    #     if (-not $ExistingPolicy) {
    #         $PolicyParams = @{
    #             Name = $SnapshotPolicy
    #             Vserver = $SVMName
    #             Enabled = $true
    #         }
    #         New-NcSnapshotPolicy @PolicyParams -ErrorAction Stop
            
    #         # Add schedules to policy
    #         Add-NcSnapshotPolicySchedule -Policy $SnapshotPolicy -Schedule "hourly" -Count 6 -Vserver $SVMName
    #         Add-NcSnapshotPolicySchedule -Policy $SnapshotPolicy -Schedule "daily" -Count 30 -Vserver $SVMName  
    #         Add-NcSnapshotPolicySchedule -Policy $SnapshotPolicy -Schedule "weekly" -Count 12 -Vserver $SVMName
            
    #         # Apply policy to volume
    #         Set-NcVol -Name $VolumeName -SnapshotPolicy $SnapshotPolicy -Vserver $SVMName
            
    #         Write-Log "Snapshot policy created and applied" -Level "SUCCESS"
    #     } else {
    #         Write-Log "Snapshot policy already exists" -Level "WARNING"
    #     }
    # } catch {
    #     Write-Log "Failed to create snapshot policy: $($_.Exception.Message)" -Level "WARNING"
    # }

    # Generate Summary Report
    Write-Log "Generating configuration summary" -Level "SUCCESS"
    Write-Host "`n" -ForegroundColor Green
    Write-Host "=== DYNAMIC HOME DIRECTORY CONFIGURATION COMPLETE ===" -ForegroundColor Green
    Write-Host "Volume: $VolumeName ($VolumeSize)" -ForegroundColor Cyan
    Write-Host "Dynamic Share Name: $DynamicShareName" -ForegroundColor Cyan
    Write-Host "Share Path: $SharePath" -ForegroundColor Cyan
    Write-Host "Search Path: $SearchPath" -ForegroundColor Cyan
    Write-Host "Junction Path: $JunctionPath" -ForegroundColor Cyan
    Write-Host "User Quota: $UserQuota (Soft: $UserSoftQuota)" -ForegroundColor Cyan
    Write-Host "`nSimplified Dynamic User Access:" -ForegroundColor Yellow
    
    foreach ($username in $UserList) {
        Write-Host "  User '$username' connects to: \\$($CIFSServer.CifsServer)\$username" -ForegroundColor White
        Write-Host "    (Automatically resolves to: $JunctionPath/$username)" -ForegroundColor Gray
    }
    
    Write-Host "`nHow it works (Simplified %w/%w configuration):" -ForegroundColor Yellow
    Write-Host "1. Share name '%w' dynamically becomes the username" -ForegroundColor White
    Write-Host "2. Share path '%w' maps to the username directory" -ForegroundColor White  
    Write-Host "3. Search path '$SearchPath' is the volume root containing user directories" -ForegroundColor White
    Write-Host "4. When user 'jsmith' connects to '\\server\jsmith':" -ForegroundColor White
    Write-Host "   - Share name %w resolves to 'jsmith'" -ForegroundColor Gray
    Write-Host "   - Share path %w resolves to 'jsmith'" -ForegroundColor Gray
    Write-Host "   - ONTAP searches '$SearchPath/jsmith'" -ForegroundColor Gray
    Write-Host "   - User is connected directly to their personal directory" -ForegroundColor Gray
    
    Write-Host "`nTest Commands:" -ForegroundColor Yellow
    foreach ($username in $UserList) {
        Write-Host "  net use H: \\$($CIFSServer.CifsServer)\$username" -ForegroundColor White
    }
    
    Write-Host "`nNext Steps:" -ForegroundColor Yellow
    Write-Host "1. Test each user's access with the commands above" -ForegroundColor White
    Write-Host "2. Verify users can only access their own directories" -ForegroundColor White
    Write-Host "3. Configure Group Policy for automatic H: drive mapping" -ForegroundColor White
    Write-Host "4. Monitor quota usage and directory access logs" -ForegroundColor White
    
    Write-Log "Simplified dynamic home directory setup completed successfully!" -Level "SUCCESS"

} catch {
    Write-Log "Script failed: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    exit 1
} finally {
    # Cleanup any remaining connections
    if ($Controller) {
        Write-Log "Disconnecting from ONTAP cluster"
    }
}
