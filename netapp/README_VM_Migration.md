# VM Migration Script (vSphere 7 to vSphere 8 with NetApp ONTAP)

## Overview

This enterprise-grade PowerShell script (`Invoke-VMigration.ps1`) automates the migration of VMs from a source vSphere 7 environment to a target vSphere 8 environment, both backed by NetApp ONTAP NFS datastores with SnapMirror replication.

## Features

- **Complete automation** of all 10 migration steps
- **Enterprise-grade logging** with color-coded console output and detailed log files
- **WhatIf mode** for safe testing without making changes
- **Idempotent design** with extensive sanity checks and validation
- **Interactive credential prompts** for security
- **Comprehensive error handling** with rollback capabilities
- **Progress tracking** and detailed status reporting

## Prerequisites

### PowerShell Modules
```powershell
Install-Module VMware.PowerCLI -Force
Install-Module NetApp.ONTAP -Force
```

### Required Permissions
- **Source vCenter**: Administrator or VM migration permissions
- **Target vCenter**: Administrator or VM registration/configuration permissions  
- **Target ONTAP Cluster**: Cluster administrator or SVM administrator permissions
- **Guest OS**: Local Administrator or Domain Administrator credentials for IP configuration

### Infrastructure Requirements
- SnapMirror relationships established between source and target ONTAP volumes
- Target NFS SVM configured with appropriate data LIFs
- Target port groups/VLANs configured in target vCenter
- Network connectivity between all components
- VMware Tools installed and running on all VMs (required for guest IP configuration)

## CSV Input Format

Create a CSV file with the following required columns:

| Column | Description | Example |
|--------|-------------|---------|
| VMName | Name of the VM to migrate | VM-WEB01 |
| VMDatastore | Source datastore name | DS_Web_Tier |
| TargetVLAN | Target VLAN/Port Group name | VLAN_100 |
| TargetIP | New IP address for automated configuration | 192.168.100.10 |
| TargetSNMask | Subnet mask for automated configuration | 255.255.255.0 |
| TargetGW | Gateway for automated configuration | 192.168.100.1 |
| TargetDNS1 | Primary DNS for automated configuration | 192.168.1.10 |
| TargetDNS2 | Secondary DNS for automated configuration | 192.168.1.11 |

**Note**: IP configuration is automatically applied to guest OS using Invoke-VMScript. Use `-SkipGuestIPConfig` to disable automated configuration.

See `VMMigration_Template.csv` for an example.

## Usage

### Testing Mode (Recommended First)
```powershell
.\Invoke-VMigration.ps1 -CSVPath "VMMigration.csv" `
                       -SourcevCenter "vcenter7.domain.com" `
                       -TargetvCenter "vcenter8.domain.com" `
                       -TargetONTAPCluster "ontap-cluster.domain.com" `
                       -TargetNFSSVM "nfs_svm" `
                       -WhatIf
```

### Production Execution
```powershell
.\Invoke-VMigration.ps1 -CSVPath "VMMigration.csv" `
                       -SourcevCenter "source-vc.domain.com" `
                       -TargetvCenter "target-vc.domain.com" `
                       -TargetONTAPCluster "target-ontap.domain.com" `
                       -TargetNFSSVM "migration_svm" `
                       -LogPath "D:\Logs\Migration_$(Get-Date -Format 'yyyyMMdd').log" `
                       -BackupTier "Tier2"

### Skip Automated IP Configuration
```powershell
.\Invoke-VMigration.ps1 -CSVPath "VMMigration.csv" `
                       -SourcevCenter "source-vc.domain.com" `
                       -TargetvCenter "target-vc.domain.com" `
                       -TargetONTAPCluster "target-ontap.domain.com" `
                       -TargetNFSSVM "migration_svm" `
                       -SkipGuestIPConfig
```

## Migration Process (10 Steps)

The script executes the following steps in order:

1. **Discover NFS Datastores** - Identifies source datastores for all VMs
2. **Power Off Source VMs** - Graceful shutdown with fallback to force power-off
3. **Update SnapMirror Relationships** - Update, quiesce, and break SnapMirror links
4. **Mount Target Datastores** - Mount NFS datastores on target cluster hosts
5. **Register Target VMs** - Register VMs in target vCenter from VMX files
6. **Update Network Configuration** - Attach VMs to target VLANs/port groups
7. **Power On Target VMs** - Start VMs and answer relocation questions ("I moved it")
7.5. **Configure Guest IP Settings** - Automatically configure IP settings inside VMs using Invoke-VMScript
8. **Apply Backup Tags** - Tag VMs with specified backup tier
9. **Disconnect Source Networks** - Disconnect network adapters on source VMs (confirmation required)
10. **Unregister Source VMs** - Remove VMs from source vCenter inventory (confirmation required)

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| CSVPath | Yes | - | Path to CSV file with VM migration data |
| SourcevCenter | Yes | - | Source vCenter Server FQDN/IP |
| TargetvCenter | Yes | - | Target vCenter Server FQDN/IP |
| TargetONTAPCluster | Yes | - | Target ONTAP cluster FQDN/IP |
| TargetNFSSVM | Yes | - | Target NFS SVM name |
| GuestCredentials | No | Prompted | PSCredential for guest OS operations |
| SkipGuestIPConfig | No | False | Skip automated guest IP configuration |
| LogPath | No | Current dir + timestamp | Log file location |
| BackupTier | No | "Tier3" | Backup tier tag to apply |
| WhatIf | No | False | Test mode without making changes |

## Logging and Monitoring

### Log Levels
- **INFO**: General information and progress updates
- **SUCCESS**: Successful operations (green)
- **WARNING**: Non-critical issues (yellow) 
- **ERROR**: Critical issues requiring attention (red)

### Log Locations
- **Console**: Real-time color-coded output
- **File**: Detailed log with timestamps (configurable location)

### Migration Summary
At completion, the script provides:
- Total VMs processed
- Error and warning counts
- Log file location
- Overall status assessment

## Safety Features

### Confirmation Points
- **Step 9**: Confirms before disconnecting source VM networks
- **Step 10**: Confirms before unregistering source VMs (irreversible)

### WhatIf Mode
- Shows all actions that would be performed
- Does not make any actual changes
- Validates CSV format and connectivity

### Error Handling
- Graceful handling of individual VM failures
- Continues processing remaining VMs when possible
- Detailed error logging for troubleshooting

## Automated Guest IP Configuration

The script automatically configures IP settings within guest operating systems using `Invoke-VMScript`. This feature:

### Supported Operating Systems
- **Windows**: Windows 2012 R2 and later (using PowerShell NetTCPIP module)
- **Linux**: Modern distributions with NetworkManager, systemd-networkd, or traditional networking
  - RHEL/CentOS 7+, Ubuntu 16.04+, SLES 12+, Debian 9+

### How It Works
1. **Detection**: Automatically detects guest OS family (Windows/Linux)
2. **Network Manager Detection**: For Linux, detects NetworkManager, systemd-networkd, or traditional networking
3. **Configuration**: Applies IP, subnet mask, gateway, and DNS settings
4. **Validation**: Tests gateway connectivity after configuration
5. **Logging**: Provides detailed output of configuration changes

### Requirements for Guest IP Configuration
- **VMware Tools**: Must be installed and running ("toolsOk" status)
- **Credentials**: Local Administrator (Windows) or root/sudo user (Linux)
- **Network Adapter**: At least one active network interface
- **Permissions**: Script execution permissions in guest OS

### Skipping IP Configuration
Use `-SkipGuestIPConfig` parameter to disable automated IP configuration if:
- VMs use DHCP instead of static IPs
- Custom network configuration is required
- Guest OS is not supported
- VMware Tools is not available

## Post-Migration Tasks

After successful migration, you may need to:

1. **Verify IP Configuration** - Check that automated IP configuration was applied correctly
2. **Update DNS Records** - Point DNS entries to new IP addresses (if not done automatically)
3. **Verify Application Connectivity** - Test all services and applications
4. **Update Monitoring** - Adjust monitoring tools for new environment
5. **Update Backup Policies** - Ensure backup systems recognize migrated VMs
6. **Clean up Source Environment** - Remove old SnapMirror relationships if desired

## Troubleshooting

### Common Issues

**Module Import Failures**
```powershell
Install-Module VMware.PowerCLI -Force -Scope CurrentUser
Install-Module NetApp.ONTAP -Force -Scope CurrentUser
```

**Connection Issues**
- Verify network connectivity to all components
- Check firewall rules (vCenter: 443, ONTAP: 443/80)
- Validate credentials and permissions

**SnapMirror Issues**  
- Ensure relationships are healthy before migration
- Check for active transfers that may delay operations
- Verify destination volumes have sufficient space

**VM Registration Failures**
- Confirm VMX files are accessible in target datastores
- Check for naming conflicts in target environment
- Verify target hosts can access the datastores

**Guest IP Configuration Failures**
- Verify VMware Tools is installed and running ("toolsOk" status)
- Check guest credentials have administrative privileges
- Ensure PowerShell execution policy allows scripts (Windows)
- Verify network interface naming conventions (Linux)
- Check for custom network configurations that may conflict

### Log Analysis

Search for specific patterns in log files:
```powershell
# Find all errors
Select-String "ERROR" -Path "Migration_Log.txt"

# Find specific VM issues
Select-String "VM-WEB01" -Path "Migration_Log.txt"

# Check SnapMirror operations
Select-String "SnapMirror" -Path "Migration_Log.txt"

# Check guest IP configuration
Select-String "IP configuration" -Path "Migration_Log.txt"
```

## Support

For issues or enhancements:
1. Review the detailed log file
2. Check PowerShell execution policies
3. Verify all prerequisites are met
4. Test with WhatIf mode first

## Security Considerations

- **Credentials**: Script prompts interactively for security
- **Logging**: Credentials are never logged in plain text
- **Permissions**: Use principle of least privilege
- **Network**: Ensure secure connections to all infrastructure

## Version History

- **v1.0**: Initial release with full migration automation
  - All 10 migration steps implemented
  - Enterprise logging and error handling
  - WhatIf mode support
  - Interactive credential collection
  - Automated guest OS IP configuration (Windows and Linux)
  - VMware Tools readiness validation
