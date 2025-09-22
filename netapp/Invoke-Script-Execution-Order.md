# Invoke-CIFSSVMTakeover.ps1 - Corrected Execution Order

## Overview
The script has been reordered to follow the proper sequence for CIFS SVM takeover operations, ensuring minimal service disruption and proper data protection.

## Corrected Execution Sequence

### **Step 11: Check for Active CIFS Sessions**
- Scans for active CIFS sessions on the source SVM
- Prompts user for confirmation if active sessions are found
- Allows force override with `-ForceSourceDisable` parameter

### **Step 12: Disable Source CIFS Server** ✅ **#1 in Required Order**
- **FIRST ACTION**: Stops the CIFS server on the source SVM
- Prevents new connections and cleanly disconnects existing sessions
- Verifies the CIFS server is properly stopped

### **Step 13: Final SnapMirror Update** ✅ **#2 in Required Order**
- **SECOND ACTION**: Performs final SnapMirror updates after CIFS is offline
- Ensures minimal data lag before breaking the relationship
- Waits for update completion before proceeding

### **Step 14: Break SnapMirror Relationships** ✅ **#3 & #4 in Required Order**
- **THIRD ACTION**: Quiesces SnapMirror relationships
- **FOURTH ACTION**: Breaks SnapMirror relationships (making volumes RW)
- **VERIFICATION**: Checks if volumes are automatically mounted after break
- **LOGGING**: Records mount status for each volume

### **Step 15: Create CIFS Shares and ACLs** ✅ **#5 & #6 in Required Order**
- **FIFTH ACTION**: Mounts volumes manually if not auto-mounted during SnapMirror break
- **SIXTH ACTION**: Creates all exported CIFS shares with REST-compatible parameters
- **ZAPI INTEGRATION**: Automatically configures advanced properties (OpLocks, ChangeNotify, ABE, etc.)
- **SIXTH ACTION**: Applies all exported share ACLs
- Filters out system shares automatically
- **No manual intervention** needed for advanced share properties

### **Step 16: Take Source LIFs Down** ✅ **#7 Preparation**
- Sets source LIFs to administratively down status
- Prepares for IP address migration to target

### **Step 17: Migrate LIF IP Addresses** ✅ **#7 in Required Order** 
- **SEVENTH ACTION**: Migrates IP addresses from source LIFs to target LIFs
- Takes target LIFs down, updates IP/netmask, brings them back up
- Verifies successful IP migration for each LIF

### **Step 18: Verify Target CIFS Server**
- Final verification that target SVM CIFS server is running
- Logs warnings if target CIFS server needs manual intervention

## Key Features

### **Volume Mounting Verification**
- After SnapMirror break, the script checks if volumes were automatically mounted
- If not auto-mounted, volumes are mounted manually during share creation
- Junction paths are derived from exported share paths

### **ZAPI Integration for Advanced Properties**
- REST-compatible share parameters are used for basic share creation
- **ZAPI (Invoke-NcSystemApi)** automatically configures advanced properties during share creation
- **Supported properties**: OpLocks, ChangeNotify, AccessBasedEnumeration, Browsable, ShowSnapshot, AttributeCache, BranchCache, ContinuouslyAvailable, ShadowCopy, HomeDirectory
- **No separate script needed** - all properties configured in one operation

### **Error Handling**
- Comprehensive error handling with rollback capabilities
- Force options for scenarios with active sessions
- Detailed logging for troubleshooting

## Files Created/Referenced

### **Input Files (from Export)**
- `CIFS-Shares.json` - Exported share configurations
- `CIFS-ShareACLs.json` - Exported share ACL entries  
- `Share-Volumes.json` - Volume validation data (optional)

### **Output Files**
- `CIFS-SVM-Takeover-YYYY-MM-DD-HH-mm-ss.txt` - Detailed execution log

## Usage Example

```powershell
# Complete CIFS SVM takeover with exported configuration
.\Invoke-CIFSSVMTakeover.ps1 `
    -SourceCluster "source-cluster.domain.com" `
    -TargetCluster "target-cluster.domain.com" `
    -SourceSVM "source_svm" `
    -TargetSVM "target_svm" `
    -ExportPath "C:\Export\source_svm_Export_2024-01-01_12-00-00" `
    -WhatIf
```

## Next Steps After Execution

1. **Test connectivity** to the new IP addresses
2. **Update DNS records** if necessary  
3. **Verify CIFS shares** are accessible via target SVM
4. **Configure advanced share properties** with `Set-ONTAPCIFSAdvancedProperties.ps1` if needed
5. **Monitor** for any client connection issues

## Validation Points

- ✅ Source CIFS server disabled **before** SnapMirror operations
- ✅ SnapMirror update → quiesce → break sequence properly executed
- ✅ Volume mounting verified and handled appropriately  
- ✅ CIFS shares and ACLs created **after** volumes are available
- ✅ LIF IP migration happens **last** to complete the cutover