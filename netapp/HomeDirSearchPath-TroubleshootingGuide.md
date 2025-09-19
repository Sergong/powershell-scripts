# CIFS Home Directory Search Path Troubleshooting Guide

## Issue Description
The `Create-DynamicUserShares.ps1` script was not properly configuring the home directory search path, which is critical for dynamic share functionality with `%w` variables.

## Root Cause Analysis

### Original Problem
The original search path configuration had these issues:
1. **Generic error handling** - Try-catch block was too broad and masked actual errors
2. **No verification** - Script didn't verify if the search path was actually added
3. **Silent failures** - Errors were logged as warnings, not errors
4. **No troubleshooting info** - Limited guidance when configuration failed

### Why Search Paths Are Critical
For dynamic shares using `%w` (username variables) to work properly:
1. **Share Name:** `%w` resolves to the username (e.g., `jsmith`)
2. **Share Path:** `%w` resolves to the username directory
3. **Search Path:** ONTAP uses this to find the actual directory location
4. **Final Resolution:** `/volume_name/users/jsmith` when user connects to `\\server\jsmith`

## Improvements Made

### 1. Enhanced Error Handling in Main Script
```powershell
# Before: Generic try-catch that masked errors
try {
    Add-NcCifsHomeDirSearchPath @SearchPathParams
    Write-Log "Home directory search path configured" -Level "SUCCESS"
} catch {
    Write-Log "Search path may already exist" -Level "WARNING"  # Too generic!
}

# After: Specific error handling with verification
$ExistingSearchPaths = Get-NcCifsHomeDirSearchPath -Vserver $SVMName -ErrorAction SilentlyContinue
$SearchPathExists = $ExistingSearchPaths | Where-Object { $_.Path -eq $SearchPath }

if ($SearchPathExists) {
    Write-Log "Search path already exists: $SearchPath" -Level "WARNING"
} else {
    try {
        Add-NcCifsHomeDirSearchPath @SearchPathParams
        Write-Log "Search path configured: $SearchPath" -Level "SUCCESS"
        
        # Verify it was actually added
        $VerifySearchPaths = Get-NcCifsHomeDirSearchPath -Vserver $SVMName
        $NewSearchPath = $VerifySearchPaths | Where-Object { $_.Path -eq $SearchPath }
        if ($NewSearchPath) {
            Write-Log "Verified search path was added successfully" -Level "SUCCESS"
        } else {
            Write-Log "Search path may not have been added properly" -Level "WARNING"
        }
    } catch {
        Write-Log "Failed to add search path: $($_.Exception.Message)" -Level "ERROR"
        # Provide troubleshooting information
    }
}
```

### 2. Current Search Path Display
The improved script now always displays current search paths for verification:
```powershell
# Always show current search paths for verification
Write-Log "Current home directory search paths:"
$CurrentSearchPaths = Get-NcCifsHomeDirSearchPath -Vserver $SVMName
if ($CurrentSearchPaths) {
    foreach ($path in $CurrentSearchPaths) {
        Write-Log "  Search Path: $($path.Path)" -Level "INFO"
    }
} else {
    Write-Log "  No search paths currently configured!" -Level "WARNING"
}
```

### 3. Standalone Troubleshooting Utility
Created `Set-CIFSHomeDirSearchPath.ps1` for dedicated search path management:

**List current search paths:**
```powershell
.\Set-CIFSHomeDirSearchPath.ps1 -ClusterName "cluster1.com" -SVMName "svm_cifs" -ListOnly
```

**Add a search path:**
```powershell
.\Set-CIFSHomeDirSearchPath.ps1 -ClusterName "cluster1.com" -SVMName "svm_cifs" -SearchPath "/user_homes/users"
```

**Force reconfigure existing path:**
```powershell
.\Set-CIFSHomeDirSearchPath.ps1 -ClusterName "cluster1.com" -SVMName "svm_cifs" -SearchPath "/user_homes/users" -Force
```

**Remove a search path:**
```powershell
.\Set-CIFSHomeDirSearchPath.ps1 -ClusterName "cluster1.com" -SVMName "svm_cifs" -SearchPath "/user_homes/users" -Remove
```

### 4. Helper Function in Main Script
Added `Set-HomeDirSearchPath` function for manual troubleshooting within the main script.

## Troubleshooting Steps

### Step 1: Check Current Search Paths
```powershell
# Connect to ONTAP and check current configuration
Connect-NcController -Name "your-cluster.com" -Credential (Get-Credential)
Get-NcCifsHomeDirSearchPath -Vserver "your_svm_name"
```

### Step 2: Verify Volume and Junction Path
```powershell
# Ensure the volume exists and has proper junction path
Get-NcVol -Name "user_homes" -Vserver "your_svm_name"

# Should show something like:
# Name         JunctionPath    State
# user_homes   /user_homes     online
```

### Step 3: Check Directory Structure
The search path should point to the parent directory containing user folders:
```
Volume: user_homes (junction: /user_homes)
├── users/
│   ├── jsmith/     <- User directories
│   ├── bmiller/
│   └── sthomas/
└── other files...

Search Path: /user_homes/users  <- Points to users directory
```

### Step 4: Test Dynamic Share Resolution
```powershell
# Check if dynamic share exists
Get-NcCifsShare -Name "%w" -Vserver "your_svm_name"

# Should show:
# Name  Path  ShareProperties
# %w    %w    {homedirectory, oplocks, browsable, changenotify}
```

### Step 5: Manual Search Path Configuration
If the main script fails, use the standalone utility:
```powershell
.\Set-CIFSHomeDirSearchPath.ps1 -ClusterName "cluster.com" -SVMName "svm_cifs" -SearchPath "/user_homes/users"
```

## Common Issues and Solutions

### Issue 1: "Path does not exist"
**Error:** Search path points to non-existent directory
**Solution:** 
- Verify volume junction path: `Get-NcVol -Name volume_name`
- Check if users directory exists in the volume
- Ensure proper forward slash format: `/volume/users` not `\volume\users`

### Issue 2: "Access denied"
**Error:** Insufficient permissions to configure search paths
**Solution:**
- Verify cluster admin credentials
- Check SVM admin permissions
- Ensure proper ONTAP RBAC roles

### Issue 3: Search path exists but dynamic shares don't work
**Possible causes:**
- CIFS share missing `homedirectory` property
- User directories don't exist
- NTFS permissions blocking access
- DNS/NetBIOS name resolution issues

### Issue 4: Multiple search paths conflict
**Solution:** List all search paths and remove conflicting ones:
```powershell
# List all paths
Get-NcCifsHomeDirSearchPath -Vserver "svm_name"

# Remove unwanted paths
Remove-NcCifsHomeDirSearchPath -Path "/old/path" -Vserver "svm_name"
```

## Verification Commands

After configuration, verify everything works:

### 1. Check ONTAP Configuration
```powershell
# Search paths
Get-NcCifsHomeDirSearchPath -Vserver "svm_name"

# Dynamic share
Get-NcCifsShare -Name "%w" -Vserver "svm_name"

# CIFS server info
Get-NcCifsServer -VserverContext "svm_name"
```

### 2. Test from Windows Client
```cmd
# Test user access (replace with actual server name and username)
net use H: \\server\jsmith

# Check mapped drive
net use

# Browse to mapped drive
dir H:
```

### 3. ONTAP CLI Verification
```bash
# From ONTAP CLI
vserver cifs home-directory search-path show -vserver svm_name
vserver cifs share show -vserver svm_name -share-name %w
```

## Best Practices

1. **Always verify configuration** after making changes
2. **Test with actual users** before deploying to production
3. **Use consistent path formats** (forward slashes for ONTAP paths)
4. **Monitor ONTAP logs** for authentication and access issues
5. **Document search path configurations** for future reference
6. **Use the standalone utility** for isolated troubleshooting

The improved error handling and verification in the main script, combined with the standalone troubleshooting utility, should resolve search path configuration issues and provide clear feedback when problems occur.