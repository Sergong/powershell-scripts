# CIFS SVM Migration Workflow

## Overview
This document describes the simplified 2-step workflow for migrating CIFS shares and services between NetApp ONTAP SVMs. The workflow includes automatic volume mounting, CIFS share creation with advanced properties via ZAPI, and seamless IP migration.

## Simplified Workflow

### Prerequisites: Initial Setup
**Objective**: Set up target SVM and establish SnapMirror relationships

1. **Configure Target SVM**
   - Create target SVM on destination cluster
   - Enable CIFS protocol
   - Configure CIFS server (domain/workgroup settings)
   - Create target volumes (typically via SnapMirror initialization)

2. **Establish SnapMirror Relationships**
   - Set up SnapMirror relationships from source volumes to target volumes
   - Allow SnapMirror replication to sync data

---

### Step 1: Export CIFS Configuration
**Objective**: Export complete CIFS share and ACL configuration

```powershell
.\Export-ONTAPCIFSConfiguration.ps1 -SourceCluster "source.domain.com" -SourceSVM "source_svm" -ExportPath "C:\Migration"
```

**What's Exported**:
- ✅ CIFS shares configuration (including advanced properties)
- ✅ CIFS share ACLs
- ✅ Volume names extracted from share paths (for validation)
- ✅ ShareProperties, SymlinkProperties, VscanProfile settings

### Step 2: Complete Migration (All-in-One)
**Objective**: Execute complete CIFS migration including SnapMirror break, volume mounting, share creation, and IP migration

```powershell
# Complete automated migration (recommended) - auto-discovers volumes and LIFs
.\Invoke-CIFSSVMTakeover.ps1 -SourceCluster "source.domain.com" -TargetCluster "target.domain.com" -SourceSVM "source_svm" -TargetSVM "target_svm" -ExportPath "C:\Migration\source_svm_Export_timestamp"

# Test run first (highly recommended)
.\Invoke-CIFSSVMTakeover.ps1 -SourceCluster "source.domain.com" -TargetCluster "target.domain.com" -SourceSVM "source_svm" -TargetSVM "target_svm" -ExportPath "C:\Migration\source_svm_Export_timestamp" -WhatIf

# Manual LIF specification (if needed)
.\Invoke-CIFSSVMTakeover.ps1 -SourceCluster "source.domain.com" -TargetCluster "target.domain.com" -SourceSVM "source_svm" -TargetSVM "target_svm" -SourceLIFNames @("source_lif1", "source_lif2") -TargetLIFNames @("target_lif1", "target_lif2") -ExportPath "C:\Migration\source_svm_Export_timestamp"
```

**Complete Migration Process**:
1. **Discovery & Validation**:
   - Auto-discover CIFS LIFs on source and target SVMs (if not specified)
   - Auto-discover active SnapMirror volumes on target SVM
   - Validate 1:1 LIF mapping between source and target
   - Validate discovered volumes against exported share data

2. **Source CIFS Service Shutdown** (Step 1):
   - Check for active CIFS sessions on source
   - Gracefully stop CIFS server on source SVM
   - Prevent new connections during migration

3. **SnapMirror Operations** (Steps 2-4):
   - Perform final SnapMirror update (captures any last changes)
   - Quiesce SnapMirror relationships  
   - Break SnapMirror relationships (makes volumes RW)
   - **Automatic volume mounting verification** - mounts volumes if needed

4. **CIFS Configuration Creation** (Steps 5-6):
   - **Mount volumes** at correct junction paths (derived from share paths)
   - **Create all CIFS shares** with exported configuration
   - **Apply advanced properties** (OpLocks, ChangeNotify, ABE, etc.) via **ZAPI integration**
   - **Apply all share ACLs** with proper permissions
   - Filter out system shares automatically

5. **IP Address Migration** (Step 7):
   - Take source LIFs administratively down
   - Migrate IP addresses from source LIFs to target LIFs (1:1 mapping)
   - Bring target LIFs up with source IP addresses
   - Verify target CIFS server is running

**🎯 Result**: Complete CIFS migration with zero configuration loss and minimal downtime!

## Complete Migration Examples

### Basic 2-Step Migration
```powershell
# Step 1: Export CIFS configuration (can be done anytime)
.\Export-ONTAPCIFSConfiguration.ps1 -SourceCluster "prod-ontap-01.domain.com" -SourceSVM "cifs_svm_01" -ExportPath "C:\Migrations"

# Step 2: Execute complete migration (includes everything!)
.\Invoke-CIFSSVMTakeover.ps1 -SourceCluster "prod-ontap-01.domain.com" -TargetCluster "prod-ontap-02.domain.com" -SourceSVM "cifs_svm_01" -TargetSVM "cifs_svm_02" -ExportPath "C:\Migrations\cifs_svm_01_Export_2024-01-15_10-30-00"
```

### Recommended Testing Approach
```powershell
# Step 1: Export (same as above)
.\Export-ONTAPCIFSConfiguration.ps1 -SourceCluster "prod-ontap-01.domain.com" -SourceSVM "cifs_svm_01" -ExportPath "C:\Migrations"

# Step 2: Test the complete migration first (HIGHLY RECOMMENDED)
.\Invoke-CIFSSVMTakeover.ps1 -SourceCluster "prod-ontap-01.domain.com" -TargetCluster "prod-ontap-02.domain.com" -SourceSVM "cifs_svm_01" -TargetSVM "cifs_svm_02" -ExportPath "C:\Migrations\cifs_svm_01_Export_2024-01-15_10-30-00" -WhatIf

# Step 3: Execute for real (remove -WhatIf)
.\Invoke-CIFSSVMTakeover.ps1 -SourceCluster "prod-ontap-01.domain.com" -TargetCluster "prod-ontap-02.domain.com" -SourceSVM "cifs_svm_01" -TargetSVM "cifs_svm_02" -ExportPath "C:\Migrations\cifs_svm_01_Export_2024-01-15_10-30-00"
```

## Prerequisites

### Source SVM Requirements
- ✅ CIFS service enabled and running
- ✅ CIFS shares configured
- ✅ One or more CIFS data LIFs (will be auto-discovered)

### Target SVM Requirements
- ✅ SVM created and CIFS protocol enabled
- ✅ CIFS server configured (same domain/workgroup as source)
- ✅ Target volumes created (via SnapMirror or other method)
- ✅ CIFS data LIFs created (same count as source, will be auto-discovered)
- ✅ Network routing configured for target IPs

### SnapMirror Requirements
- ✅ SnapMirror relationships established and synchronized
- ✅ Target volumes accessible via same junction paths as source

## Advantages of Simplified Workflow

1. **🚀 Ultra-Simple**: Just 2 steps - Export → Invoke (complete migration)
2. **⚙️ Zero Configuration Loss**: All share properties preserved via ZAPI integration
3. **🔄 Automatic Everything**: Volume mounting, share creation, ACLs, advanced properties, IP migration
4. **⏱️ Minimal Downtime**: Single cutover window with all operations in correct sequence
5. **📝 Comprehensive Testing**: Full `-WhatIf` support for complete dry-run validation
6. **🔍 Auto-Discovery**: Automatically discovers SnapMirror volumes and CIFS LIFs
7. **📊 Advanced Properties**: OpLocks, ChangeNotify, ABE, etc. configured automatically via ZAPI
8. **📝 Dynamic Share Support**: Full support for ONTAP dynamic shares with variable substitution
9. **🔄 Flexible LIF Support**: Works with single or multiple CIFS LIFs (1:1 mapping)
10. **📊 Volume Validation**: Cross-validates SnapMirror volumes against exported share data
11. **💻 PowerShell 7 Compatible**: Works with both Windows PowerShell and PowerShell 7
12. **🔐 Correct Execution Order**: CIFS disable → SnapMirror → Shares → LIF migration

## Troubleshooting

### Common Issues
- **"CIFS server not configured"**: Ensure target SVM has CIFS server configured before import
- **"Volume not found"**: Verify target volumes exist and have correct junction paths
- **"SnapMirror break failed"**: Check SnapMirror status and ensure no active transfers
- **"No SnapMirror volumes discovered"**: Verify SnapMirror relationships exist and are active on target SVM
- **"Volume validation warnings"**: Review mismatches between SnapMirror volumes and exported share volumes
- **"No CIFS LIFs found"**: Ensure both SVMs have CIFS data LIFs configured
- **"LIF count mismatch"**: Source and target SVMs must have same number of CIFS LIFs for 1:1 migration

### Rollback Procedure
If cutover fails:
1. Re-establish SnapMirror relationships (if needed)
2. Bring source CIFS server back online
3. Restore source LIF IP addresses
4. Remove CIFS shares from target SVM (if desired)

## Dynamic Share Support

### **What are Dynamic Shares?**
Dynamic shares use ONTAP variable substitution to create user-specific paths:
- **`%w`** - Username (e.g., `jdoe`)
- **`%d`** - Domain (e.g., `CORP`)
- **`%W`** - Username in uppercase
- **`%D`** - Domain in uppercase

### **Example Dynamic Shares:**
```
Share Name: HomeDirectories
Path: /vol_home/%w
Result: User 'jdoe' sees /vol_home/jdoe

Share Name: UserProfiles  
Path: /vol_profiles/%d/%w
Result: User 'jdoe' in 'CORP' domain sees /vol_profiles/CORP/jdoe
```

### **Migration Handling:**
✅ **Export**: Identifies and properly exports dynamic shares with variables intact  
✅ **Complete Migration**: Single script creates dynamic shares with exact variable substitution  
✅ **Auto-Properties**: Advanced share properties applied automatically via ZAPI
✅ **IP Migration**: Dynamic shares continue working seamlessly after IP migration  
✅ **Logging**: Clear identification of dynamic vs static shares in all operations

## Key Features
- **💻 PowerShell 7 Compatible**: Works with both Windows PowerShell and PowerShell Core
- **🔄 Dynamic Share Support**: Full support with variable substitution intact (%w, %d, etc.)
- **⚙️ ZAPI Integration**: Advanced share properties configured automatically
- **📝 Comprehensive Logging**: Detailed logs for troubleshooting and audit
- **📊 WhatIf Support**: Complete dry-run testing before execution
- **🛡️ Best Practices**: Follows PowerShell coding standards from WARP.md
- **🔄 Zero Manual Steps**: Complete automation from export to final migration
