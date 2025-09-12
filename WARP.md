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

- **Export/Import Pipeline**: `Export-ONTAPCIFSConfiguration.ps1` → `Import-ONTAPCIFSConfiguration.ps1`
  - Exports complete CIFS SVM configurations including shares, ACLs, and volume information
  - Imports configurations to target clusters with validation and rollback capabilities
  - Supports SnapMirror relationship handling and comprehensive logging

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

### Export CIFS Configuration
```powershell
.\Export-ONTAPCIFSConfiguration.ps1 -SourceCluster "cluster.domain.com" -SourceSVM "svm_name" -ExportPath "C:\Export" -IncludeSnapMirrorInfo
```

### Import CIFS Configuration
```powershell
.\Import-ONTAPCIFSConfiguration.ps1 -ImportPath "C:\Export\svm_name_Export_timestamp" -TargetCluster "target-cluster.domain.com" -TargetSVM "target_svm" -BreakSnapMirrors -WhatIf
```

### CIFS SVM Takeover
```powershell
.\Invoke-CIFSSVMTakeover.ps1 -SourceCluster "source.domain.com" -TargetCluster "target.domain.com" -SourceSVM "source_svm" -TargetSVM "target_svm" -SourceLIFNames @("lif1", "lif2") -TargetLIFNames @("target_lif1", "target_lif2") -WhatIf
```

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
- NetApp.ONTAP PowerShell Toolkit
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
