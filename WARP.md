# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Repository Overview

This repository contains PowerShell scripts and utilities organized by functionality, focusing primarily on NetApp ONTAP administration, system utilities, and infrastructure automation. The scripts are designed for Windows environments and NetApp storage management.

## Architecture & Organization

### Directory Structure
- **`netapp/`** - NetApp ONTAP administration scripts with comprehensive CIFS SVM management
- **`netapp/Terraform/`** - Terraform configuration for NetApp ONTAP infrastructure as code
- **`directory/`** - Directory listing utilities with human-readable output
- **`disk/`** - Windows disk and LUN information gathering scripts
- **`security/`** - Process ownership and security analysis utilities

### Core Components

#### NetApp ONTAP Scripts
The `netapp/` directory contains enterprise-grade scripts for ONTAP cluster management:

- **Export/Takeover Pipeline**: `Export-ONTAPCIFSConfiguration.ps1` → `Invoke-CIFSSVMTakeover.ps1`
  - Exports CIFS SVM configurations including shares, ACLs, and volume information  
  - Invoke script handles complete cutover: SnapMirror break, volume mounting, share/ACL creation, and LIF IP migration
  - **ZAPI Integration**: Automatically configures advanced share properties (OpLocks, ChangeNotify, ABE, etc.)
  - **Complete solution**: No additional scripts needed for CIFS migration
  - Supports comprehensive logging and `-WhatIf` dry run capabilities

- **CIFS SVM Takeover**: `Invoke-CIFSSVMTakeover.ps1`
  - Orchestrates CIFS service migration between SVMs
  - Handles LIF IP address migration and service failover
  - Includes safety checks for active sessions and proper cleanup

- **DNS Management**: `Update-CnameAndReplicate.ps1`
  - Updates CNAME records and forces AD-integrated DNS replication
  - Supports immediate DNS propagation across domain controllers

#### Infrastructure as Code
The `netapp/Terraform/` directory provides:
- NetApp ONTAP provider configuration for LIF and CIFS service provisioning
- Variable-driven configuration for multi-environment deployment
- Example configurations for network interfaces and CIFS services

## Common Development Tasks

### Running NetApp Scripts

All NetApp scripts require the NetApp PowerShell Toolkit:
```powershell
Install-Module NetApp.ONTAP -Force
Import-Module NetApp.ONTAP
```

### CIFS Migration Workflow (Simple 2-Step Process)

#### Step 1: Export CIFS Configuration
```powershell
.\Export-ONTAPCIFSConfiguration.ps1 -SourceCluster "cluster.domain.com" -SourceSVM "svm_name" -ExportPath "C:\Export"
```

#### Step 2: Execute Complete Takeover
```powershell
# Complete CIFS migration: SnapMirror break, volume mounting, share/ACL creation, 
# advanced properties configuration, and LIF IP migration - all in one script
.\Invoke-CIFSSVMTakeover.ps1 -SourceCluster "source.domain.com" -TargetCluster "target.domain.com" -SourceSVM "source_svm" -TargetSVM "target_svm" -ExportPath "C:\Export\svm_name_Export_timestamp" -WhatIf
```

**That's it! Complete CIFS migration in just 2 steps.**

#### Features Included:
- ✅ **Automatic volume mounting** after SnapMirror break
- ✅ **Complete share recreation** with all exported settings
- ✅ **ACL application** with proper permissions
- ✅ **Advanced properties** (OpLocks, ChangeNotify, ABE, etc.) via ZAPI
- ✅ **LIF IP migration** for seamless client transition
- ✅ **WhatIf support** for safe testing before execution

### Terraform NetApp Deployment
```bash
cd netapp/Terraform
terraform init
terraform plan -var-file="terraform.tfvars"
terraform apply
```

### System Utilities
```powershell
# Human-readable directory listing
.\directory\get-dir.ps1 -Path "C:\SomeDirectory"

# Disk and LUN information
.\disk\get-Lun.ps1

# Process ownership analysis
.\security\get-processowner.ps1
```

## PowerShell Coding Standards

### Variable Naming
- Use `${variable}` syntax instead of `$variable:` to avoid parsing errors
- Avoid using reserved variables like `$args`
- Use descriptive parameter names and proper parameter validation

### Error Handling
- All scripts implement comprehensive try-catch blocks with proper logging
- Use `Write-Log` functions for consistent logging across NetApp scripts
- Implement `-WhatIf` parameters for safe testing of destructive operations

### Output Formatting
- Avoid special characters in `Write-Host` commands to prevent Windows failures
- Use color-coded output for status indication (Green=OK, Red=Error, Yellow=Warning)
- Implement detailed logging to files with timestamps

## NetApp ONTAP Integration

### Required Modules
- NetApp.ONTAP PowerShell Toolkit (supports both REST API and ZAPI)
- ActiveDirectory (for DNS replication scripts) 
- DnsServer (for DNS management scripts)

### Connection Management
- Scripts establish and tear down ONTAP cluster connections properly
- Support for both source and target cluster connections in migration scenarios
- Credential handling with PSCredential objects

### Data Protection Considerations
- SnapMirror relationship handling with break/quiesce operations
- Volume and share configuration preservation during migrations
- Comprehensive backup of configurations before modifications

### REST API Limitations (Now Solved)
- **ShareProperties**, **SymlinkProperties**, and **VscanProfile** are not supported via REST API calls in newer NetApp PowerShell Toolkit versions
- **Solution**: Invoke script now uses ZAPI (Invoke-NcSystemApi) to configure these properties automatically
- **Properties supported**: OpLocks, ChangeNotify, AccessBasedEnumeration, Browsable, ShowSnapshot, and more
- **No manual intervention** required - advanced properties are applied during share creation

### Simplified Workflow (Volume Mounting Dependency Solution)
- **Previous workflow issue**: Import script would fail when trying to create shares on unmounted volumes (SnapMirror DP volumes)
- **Solution**: Invoke script now reads exported configuration directly and handles everything in one operation
- **Sequence**: SnapMirror break → Volume mounting → Share/ACL creation → IP migration → Source CIFS disable
- **Result**: Simple 2-step process (Export → Invoke) with optional advanced properties configuration

## Testing and Validation

### WhatIf Support
Most NetApp scripts support `-WhatIf` parameter for safe testing:
```powershell
# Test without making changes
.\script.ps1 -WhatIf
```

### Logging and Verification
- All NetApp scripts generate timestamped log files
- Export operations create structured JSON, XML, and CSV files for review
- Import operations include verification steps and rollback capabilities

## Security Considerations

- Credential management through PSCredential objects
- Domain controller authentication for DNS operations
- CIFS session validation before service disruption
- Comprehensive audit trails through logging

## Terraform Integration

The Terraform configuration supports:
- NetApp ONTAP provider for infrastructure provisioning
- Variable-driven deployments across environments
- Network interface and CIFS service automation
- Integration with existing PowerShell-based management workflows
