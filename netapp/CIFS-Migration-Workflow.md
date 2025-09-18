# CIFS SVM Migration Workflow

## Overview
This document describes the revised workflow for migrating CIFS shares and services between NetApp ONTAP SVMs, addressing the SnapMirror timing conflict in the original design.

## Workflow

### Phase 1: Pre-Migration Setup
**Objective**: Set up target SVM and establish SnapMirror relationships

1. **Configure Target SVM**
   - Create target SVM on destination cluster
   - Enable CIFS protocol
   - Configure CIFS server (domain/workgroup settings)
   - Create target volumes (typically via SnapMirror initialization)

2. **Establish SnapMirror Relationships**
   - Set up SnapMirror relationships from source volumes to target volumes
   - Allow SnapMirror replication to sync data

### Phase 2: Export CIFS Configuration
**Objective**: Export minimal CIFS share and ACL configuration

```powershell
.\Export-ONTAPCIFSConfiguration.ps1 -SourceCluster "source.domain.com" -SourceSVM "source_svm" -ExportPath "C:\Migration"
```

**What's Exported**:
- ✅ CIFS shares configuration
- ✅ CIFS share ACLs
- ✅ Volume names extracted from share paths (for validation)


### Phase 3: Import CIFS Configuration
**Objective**: Pre-create CIFS shares on target SVM while SnapMirror is still active

```powershell
.\Import-ONTAPCIFSConfiguration.ps1 -ImportPath "C:\Migration\source_svm_Export_timestamp" -TargetCluster "target.domain.com" -TargetSVM "target_svm"
```

**What Happens**:
- ✅ CIFS shares created on target SVM
- ✅ CIFS share ACLs applied
- ✅ Works with volumes still in SnapMirror relationships
- ✅ Validates target CIFS server exists

### Phase 4: Cutover Execution
**Objective**: Break SnapMirrors and transfer IP addresses for seamless failover

```powershell
# Fully automated (recommended) - auto-discovers volumes and LIFs
.\Invoke-CIFSSVMTakeover.ps1 -SourceCluster "source.domain.com" -TargetCluster "target.domain.com" -SourceSVM "source_svm" -TargetSVM "target_svm" -ExportPath "C:\Migration\source_svm_Export_timestamp"

# Or specify LIFs manually (still auto-discovers volumes)
.\Invoke-CIFSSVMTakeover.ps1 -SourceCluster "source.domain.com" -TargetCluster "target.domain.com" -SourceSVM "source_svm" -TargetSVM "target_svm" -SourceLIFNames @("source_lif1", "source_lif2") -TargetLIFNames @("target_lif1", "target_lif2") -ExportPath "C:\Migration\source_svm_Export_timestamp"

# Or specify everything manually
.\Invoke-CIFSSVMTakeover.ps1 -SourceCluster "source.domain.com" -TargetCluster "target.domain.com" -SourceSVM "source_svm" -TargetSVM "target_svm" -SourceLIFNames @("source_lif1", "source_lif2") -TargetLIFNames @("target_lif1", "target_lif2") -SnapMirrorVolumes @("vol1", "vol2", "vol3")
```

**What Happens**:
1. **LIF Discovery & Validation**:
   - Auto-discover CIFS LIFs on source and target SVMs (if not specified)
   - Validate 1:1 LIF mapping between source and target
   - Support for single or multiple CIFS LIFs

2. **Volume Discovery & Validation**:
   - Auto-discover active SnapMirror volumes on target SVM
   - Validate discovered volumes against exported share data (if export path provided)
   - Display comprehensive volume analysis

3. **CIFS Service Shutdown**:
   - Check for active CIFS sessions on source
   - Stop CIFS server on source SVM
   - Take source LIFs administratively down

4. **Final SnapMirror Operations**:
   - Perform final SnapMirror update (captures any last changes)
   - Quiesce SnapMirror relationships
   - Break SnapMirror relationships
   - Verify volumes are read-write on target

5. **IP Address Migration**:
   - Migrate IP addresses from source LIFs to target LIFs (1:1 mapping)
   - Bring target LIFs up with source IP addresses
   - Verify target CIFS server is running

## Script Usage Examples

### Complete Migration Example
```powershell
# 1. Export CIFS configuration (can be done anytime)
.\Export-ONTAPCIFSConfiguration.ps1 -SourceCluster "prod-ontap-01.domain.com" -SourceSVM "cifs_svm_01" -ExportPath "C:\Migrations"

# 2. Import CIFS shares to target (while SnapMirror active)
.\Import-ONTAPCIFSConfiguration.ps1 -ImportPath "C:\Migrations\cifs_svm_01_Export_2024-01-15_10-30-00" -TargetCluster "prod-ontap-02.domain.com" -TargetSVM "cifs_svm_02"

# 3. Perform fully automated cutover
.\Invoke-CIFSSVMTakeover.ps1 -SourceCluster "prod-ontap-01.domain.com" -TargetCluster "prod-ontap-02.domain.com" -SourceSVM "cifs_svm_01" -TargetSVM "cifs_svm_02" -ExportPath "C:\Migrations\cifs_svm_01_Export_2024-01-15_10-30-00"
```

### Testing with WhatIf
```powershell
# Test the cutover without making changes (fully automated)
.\Invoke-CIFSSVMTakeover.ps1 -SourceCluster "prod-ontap-01.domain.com" -TargetCluster "prod-ontap-02.domain.com" -SourceSVM "cifs_svm_01" -TargetSVM "cifs_svm_02" -ExportPath "C:\Migrations\cifs_svm_01_Export_2024-01-15_10-30-00" -WhatIf
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

## Advantages of New Workflow

1. **Eliminates Timing Conflict**: Scripts can be run in logical sequence without SnapMirror state conflicts
2. **Faster Cutover**: CIFS shares are pre-configured, reducing cutover window
3. **Better Testing**: Import can be tested before cutover without affecting SnapMirror
4. **Cleaner Separation**: Each script has a focused responsibility
5. **Auto-Discovery**: Automatically discovers SnapMirror volumes and CIFS LIFs, no manual lists required
6. **Flexible LIF Support**: Works with single or multiple CIFS LIFs (1:1 mapping)
7. **Dynamic Share Support**: Full support for ONTAP dynamic shares with variable substitution
8. **Volume Validation**: Cross-validates SnapMirror volumes against exported share data
9. **PowerShell 7 Compatible**: Added credential handling for both Windows PowerShell and PowerShell 7

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
✅ **Validation**: New script to verify supporting directory structures exist on target  
✅ **Import**: Creates dynamic shares on target with exact variable substitution  
✅ **Takeover**: Dynamic shares continue working after IP migration  
✅ **Logging**: Clear identification of dynamic vs static shares in all operations

## Notes
- All scripts now include PowerShell 7 compatibility for credential input
- Dynamic shares are fully supported and migrated with variable substitution intact
- Each script generates detailed logs for troubleshooting
- Use `-WhatIf` parameter for safe testing of operations
- Scripts follow PowerShell best practices from the WARP.md rules
