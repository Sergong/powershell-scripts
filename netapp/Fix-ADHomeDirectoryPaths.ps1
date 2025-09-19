<#
.SYNOPSIS
    Fixes AD home directory paths that contain double backslashes from previous script versions
.DESCRIPTION
    Identifies and corrects AD user home directory paths that were created with invalid double backslashes
    (\\server\\username) and updates them to the correct single backslash format (\\server\username).
    
    This utility fixes issues created by previous versions of Create-DynamicUserShares.ps1 that
    had incorrect UNC path formatting.
.PARAMETER UserList
    Array of usernames to check and fix. If not specified, all users with double backslashes in HomeDirectory will be found automatically
.PARAMETER Domain
    Active Directory domain name (optional, used for filtering if UserList not specified)
.PARAMETER ServerName
    CIFS server name to search for in home directory paths (optional, helps with filtering)
.PARAMETER WhatIf
    Show what changes would be made without actually making them
.PARAMETER Force
    Skip confirmation prompts and apply fixes automatically
.EXAMPLE
    .\Fix-ADHomeDirectoryPaths.ps1 -UserList @("jsmith","bmiller","sthomas") -WhatIf
.EXAMPLE
    .\Fix-ADHomeDirectoryPaths.ps1 -Domain "COMPANY" -ServerName "fileserver" -Force
.EXAMPLE
    .\Fix-ADHomeDirectoryPaths.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$false)]
    [string[]]$UserList,
    
    [Parameter(Mandatory=$false)]
    [string]$Domain,
    
    [Parameter(Mandatory=$false)]
    [string]$ServerName,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

#Requires -Modules ActiveDirectory

# Import ActiveDirectory module
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Host "[SUCCESS] ActiveDirectory module imported successfully" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Failed to import ActiveDirectory module: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Install RSAT (Remote Server Administration Tools) to enable AD integration" -ForegroundColor Yellow
    exit 1
}

# Function to log output with timestamp
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch($Level) {
        "ERROR" { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        "INFO" { "Cyan" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# Function to fix home directory path
function Fix-HomeDirectoryPath {
    param(
        [string]$OriginalPath
    )
    
    # Pattern to match double backslashes after server name: \\server\\path
    # We want to replace \\server\\path with \\server\path
    if ($OriginalPath -match '^(\\\\[^\\]+)\\\\(.+)$') {
        $serverPart = $matches[1]  # \\server
        $pathPart = $matches[2]    # username or path
        $fixedPath = "$serverPart\$pathPart"
        return $fixedPath
    }
    
    return $OriginalPath  # No change needed
}

try {
    Write-Log "Starting AD Home Directory Path Fix Utility"
    
    # Determine which users to process
    $usersToProcess = @()
    
    if ($UserList -and $UserList.Count -gt 0) {
        Write-Log "Processing specified user list: $($UserList -join ', ')"
        foreach ($username in $UserList) {
            try {
                $user = Get-ADUser -Identity $username -Properties HomeDirectory, HomeDrive -ErrorAction Stop
                $usersToProcess += $user
            } catch {
                Write-Log "User not found or error retrieving: $username - $($_.Exception.Message)" -Level "WARNING"
            }
        }
    } else {
        Write-Log "Searching for users with double backslash home directory paths"
        
        # Build filter for finding users with problematic paths
        $filter = "HomeDirectory -like '*\\\\*'"
        
        if ($Domain) {
            Write-Log "Filtering by domain: $Domain"
            # Add domain filter if specified
            $searchBase = (Get-ADDomain -Identity $Domain).DistinguishedName
            $usersToProcess = Get-ADUser -Filter $filter -Properties HomeDirectory, HomeDrive -SearchBase $searchBase
        } else {
            $usersToProcess = Get-ADUser -Filter $filter -Properties HomeDirectory, HomeDrive
        }
        
        # Further filter by server name if specified
        if ($ServerName) {
            Write-Log "Filtering by server name: $ServerName"
            $usersToProcess = $usersToProcess | Where-Object { 
                $_.HomeDirectory -like "\\$ServerName\\*" -or $_.HomeDirectory -like "\\$ServerName.*\\*"
            }
        }
        
        # Filter to only users with actual double backslash issues (not just UNC prefix)
        $usersToProcess = $usersToProcess | Where-Object {
            $_.HomeDirectory -match '^\\\\[^\\]+\\\\[^\\]+'
        }
    }
    
    if ($usersToProcess.Count -eq 0) {
        Write-Log "No users found with double backslash home directory paths" -Level "INFO"
        exit 0
    }
    
    Write-Log "Found $($usersToProcess.Count) user(s) with potential double backslash issues"
    
    # Analyze and display findings
    Write-Host "`n=== ANALYSIS RESULTS ===" -ForegroundColor Cyan
    $problemUsers = @()
    
    foreach ($user in $usersToProcess) {
        $originalPath = $user.HomeDirectory
        $fixedPath = Fix-HomeDirectoryPath -OriginalPath $originalPath
        
        if ($originalPath -ne $fixedPath) {
            $problemUsers += [PSCustomObject]@{
                Username = $user.SamAccountName
                DisplayName = $user.Name
                HomeDrive = $user.HomeDrive
                OriginalPath = $originalPath
                FixedPath = $fixedPath
                User = $user
            }
            
            Write-Host "USER: $($user.SamAccountName) ($($user.Name))" -ForegroundColor White
            Write-Host "  Current:  $originalPath" -ForegroundColor Red
            Write-Host "  Fixed:    $fixedPath" -ForegroundColor Green
            Write-Host "  HomeDrive: $($user.HomeDrive)" -ForegroundColor Yellow
            Write-Host ""
        }
    }
    
    if ($problemUsers.Count -eq 0) {
        Write-Log "No users found with actual double backslash issues (all paths are correct)" -Level "SUCCESS"
        exit 0
    }
    
    Write-Log "Found $($problemUsers.Count) user(s) requiring home directory path fixes"
    
    # Confirmation prompt (unless -Force or -WhatIf)
    if (-not $Force -and -not $WhatIfPreference) {
        Write-Host "`nDo you want to proceed with fixing these home directory paths? (Y/N): " -NoNewline -ForegroundColor Yellow
        $response = Read-Host
        if ($response -notmatch '^[Yy]') {
            Write-Log "Operation cancelled by user" -Level "WARNING"
            exit 0
        }
    }
    
    # Apply fixes
    Write-Host "`n=== APPLYING FIXES ===" -ForegroundColor Cyan
    $successCount = 0
    $errorCount = 0
    
    foreach ($problemUser in $problemUsers) {
        try {
            if ($PSCmdlet.ShouldProcess($problemUser.Username, "Update HomeDirectory from '$($problemUser.OriginalPath)' to '$($problemUser.FixedPath)'")) {
                Set-ADUser -Identity $problemUser.Username -HomeDirectory $problemUser.FixedPath -ErrorAction Stop
                Write-Log "Fixed home directory for $($problemUser.Username): $($problemUser.FixedPath)" -Level "SUCCESS"
                $successCount++
            }
        } catch {
            Write-Log "Failed to update $($problemUser.Username): $($_.Exception.Message)" -Level "ERROR"
            $errorCount++
        }
    }
    
    # Summary
    Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
    Write-Log "Total users processed: $($problemUsers.Count)"
    Write-Log "Successfully updated: $successCount" -Level "SUCCESS"
    if ($errorCount -gt 0) {
        Write-Log "Errors encountered: $errorCount" -Level "ERROR"
    }
    
    if ($WhatIfPreference) {
        Write-Host "`nWHAT-IF MODE: No changes were actually made" -ForegroundColor Yellow
        Write-Host "Remove -WhatIf parameter to apply the fixes" -ForegroundColor Yellow
    }
    
    # Verification section
    if ($successCount -gt 0 -and -not $WhatIfPreference) {
        Write-Host "`n=== VERIFICATION ===" -ForegroundColor Cyan
        Write-Log "Verifying updated home directory paths"
        
        foreach ($problemUser in $problemUsers) {
            try {
                $updatedUser = Get-ADUser -Identity $problemUser.Username -Properties HomeDirectory -ErrorAction Stop
                if ($updatedUser.HomeDirectory -eq $problemUser.FixedPath) {
                    Write-Log "✓ Verified: $($problemUser.Username) = $($updatedUser.HomeDirectory)" -Level "SUCCESS"
                } else {
                    Write-Log "✗ Verification failed: $($problemUser.Username) = $($updatedUser.HomeDirectory)" -Level "WARNING"
                }
            } catch {
                Write-Log "Could not verify $($problemUser.Username): $($_.Exception.Message)" -Level "WARNING"
            }
        }
        
        Write-Host "`nRecommended next steps:" -ForegroundColor Yellow
        Write-Host "1. Test user login and home directory access" -ForegroundColor White
        Write-Host "2. Verify network drive mapping works correctly" -ForegroundColor White
        Write-Host "3. Check that users can access their home directories" -ForegroundColor White
    }
    
} catch {
    Write-Log "Script failed: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    exit 1
}

Write-Log "AD Home Directory Path fix utility completed"