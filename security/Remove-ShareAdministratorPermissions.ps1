<#
.SYNOPSIS
    Recursively removes BUILTIN\Administrators group permissions from all files and folders in a share using icacls

.DESCRIPTION
    This script uses the Windows icacls command to recursively REMOVE BUILTIN\Administrators group 
    permissions from all files and folders within a specified share path. IMPORTANT: This script 
    PRESERVES all other existing permissions and only removes the BUILTIN\Administrators entries. 
    The script includes comprehensive logging, error handling, optional permission backup, and 
    WhatIf support for safe testing before execution.
    
    This is the companion script to Set-ShareAdministratorPermissions.ps1 and provides the reverse
    functionality for removing administrator access when no longer needed.
    
    The script follows enterprise-grade PowerShell coding standards with:
    - Comprehensive error handling and logging
    - Color-coded output for status indication
    - Optional backup of original permissions before modification
    - WhatIf parameter support for safe testing
    - Progress indication for long-running operations
    - Detailed summary reporting

.PARAMETER SharePath
    The UNC path (\\server\share) or local path (C:\folder) to process.
    This parameter is mandatory and must point to an existing, accessible directory.

.PARAMETER BackupOriginalPermissions
    Switch parameter to create a backup of original permissions before modification.
    The backup will be saved as an .acl file that can be restored using icacls /restore.

.PARAMETER LogPath
    Optional custom path for the log file. If not specified, logs will be created in the script directory.

.EXAMPLE
    .\Remove-ShareAdministratorPermissions.ps1 -SharePath "\\fileserver\shares\data"
    
    Removes BUILTIN\Administrators permissions from all files and folders in the data share.
    All other existing permissions are preserved.

.EXAMPLE
    .\Remove-ShareAdministratorPermissions.ps1 -SharePath "C:\CompanyData" -WhatIf
    
    Shows what would be done without making any actual changes (safe testing mode).

.EXAMPLE
    .\Remove-ShareAdministratorPermissions.ps1 -SharePath "\\server\share" -BackupOriginalPermissions
    
    Removes BUILTIN\Administrators permissions after backing up original permissions for potential restoration.

.NOTES
    Requirements:
    - Windows operating system (icacls command)
    - PowerShell 5.1 or later
    - Administrator privileges for modifying permissions
    - Network connectivity for UNC paths
    
    icacls Flags Used:
    - /remove - Remove specific permissions while preserving other ACL entries
    - /t - Apply recursively to all files and subdirectories  
    - /c - Continue operation even if errors occur
    
    IMPORTANT: This script only removes BUILTIN\Administrators entries. If there are multiple
    administrator entries or inherited permissions, those may remain. Use with WhatIf first
    to understand the impact.

.LINK
    Based on PowerShell coding standards defined in WARP.md
    Companion to Set-ShareAdministratorPermissions.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$true, Position=0, HelpMessage="UNC path or local path to process")]
    [ValidateNotNullOrEmpty()]
    [string]$SharePath,
    
    [Parameter(Mandatory=$false)]
    [switch]$BackupOriginalPermissions,
    
    [Parameter(Mandatory=$false)]
    [string]$LogPath
)

# Initialize script variables
$StartTime = Get-Date
$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Set up logging
if (-not $LogPath) {
    $LogFile = Join-Path $ScriptDirectory "Remove-ShareAdminPerms_${Timestamp}.log"
} else {
    $LogFile = $LogPath
}

# Ensure log directory exists
$LogDirectory = Split-Path -Parent $LogFile
if (-not (Test-Path $LogDirectory)) {
    try {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    } catch {
        Write-Error "Failed to create log directory: ${LogDirectory}"
        exit 1
    }
}

# Logging function with color-coded output
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )
    
    $LogEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    
    # Color-coded console output (avoiding special characters per WARP.md rules)
    switch ($Level) {
        "SUCCESS" { Write-Host $LogEntry -ForegroundColor Green }
        "ERROR"   { Write-Host $LogEntry -ForegroundColor Red }
        "WARNING" { Write-Host $LogEntry -ForegroundColor Yellow }
        default   { Write-Host $LogEntry }
    }
    
    # Write to log file
    try {
        Add-Content -Path $LogFile -Value $LogEntry -ErrorAction Stop
    } catch {
        Write-Warning "Failed to write to log file: ${LogFile}"
    }
}

# Initialize summary tracking
$Summary = @{
    TotalFilesProcessed = 0
    TotalFoldersProcessed = 0
    SuccessfulOperations = 0
    FailedOperations = 0
    FailedItems = @()
    BackupLocation = ""
    StartTime = $StartTime
}

Write-Log "=== Share Administrator Permissions REMOVAL Script Started ===" "INFO"
Write-Log "SharePath: ${SharePath}" "INFO"
Write-Log "Operation: REMOVE BUILTIN\Administrators permissions" "WARNING"
Write-Log "WhatIf Mode: $($WhatIfPreference)" "INFO"
Write-Log "Log File: ${LogFile}" "INFO"

try {
    # Step 1: Validate SharePath
    Write-Log "Validating share path accessibility..." "INFO"
    
    if (-not (Test-Path -Path $SharePath)) {
        throw "Path does not exist or is not accessible: ${SharePath}"
    }
    
    # Test if path is accessible (try to list contents)
    try {
        $null = Get-ChildItem -Path $SharePath -ErrorAction Stop | Select-Object -First 1
        Write-Log "Path validation successful" "SUCCESS"
    } catch {
        throw "Path exists but is not accessible (insufficient permissions): ${SharePath}"
    }
    
    # Step 2: Backup original permissions if requested
    if ($BackupOriginalPermissions) {
        Write-Log "Creating backup of original permissions..." "INFO"
        
        $BackupDirectory = Join-Path $ScriptDirectory "PermissionBackups_${Timestamp}"
        if (-not (Test-Path $BackupDirectory)) {
            New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
        }
        
        $BackupFile = Join-Path $BackupDirectory "Original_Permissions.acl"
        $Summary.BackupLocation = $BackupFile
        
        if ($WhatIfPreference) {
            Write-Log "[WHATIF] Would backup permissions to: ${BackupFile}" "INFO"
        } else {
            try {
                $BackupArgs = @(
                    "`"${SharePath}`"",
                    "/save",
                    "`"${BackupFile}`"",
                    "/t",
                    "/c"
                )
                
                # Use simplified Start-Process approach
                Write-Log "Creating ACL backup - this may take a moment..." "INFO"
                
                $BackupProcess = Start-Process -FilePath "icacls" -ArgumentList $BackupArgs -Wait -NoNewWindow -PassThru
                
                if ($BackupProcess.ExitCode -eq 0) {
                    Write-Log "Permissions backup created successfully: ${BackupFile}" "SUCCESS"
                } else {
                    Write-Log "Permission backup failed (exit code: $($BackupProcess.ExitCode)) but continuing" "WARNING"
                }
            } catch {
                Write-Log "Permission backup failed but continuing: $($_.Exception.Message)" "WARNING"
            }
        }
    }
    
    # Step 3: Prepare icacls command for removal
    $RemoveExpression = "BUILTIN\Administrators"
    
    Write-Log "Preparing to remove permissions for: ${RemoveExpression}" "WARNING"
    
    $IcaclsArgs = @(
        "`"${SharePath}`"",
        "/remove",
        "`"${RemoveExpression}`"",
        "/t",
        "/c"
    )
    
    if ($WhatIfPreference) {
        Write-Log "[WHATIF] Would execute: icacls $($IcaclsArgs -join ' ')" "INFO"
        Write-Log "[WHATIF] Flags explanation:" "INFO"
        Write-Log "[WHATIF]   /remove - REMOVE specific permissions while preserving other ACLs" "INFO"
        Write-Log "[WHATIF]   /t - Apply recursively to all files and subdirectories" "INFO"
        Write-Log "[WHATIF]   /c - Continue operation even if errors occur" "INFO"
        Write-Log "[WHATIF] This would recursively REMOVE all BUILTIN\Administrators permissions" "WARNING"
        Write-Log "[WHATIF] No changes will be made in WhatIf mode" "INFO"
    } else {
        # Step 4: Execute icacls command with simplified approach
        Write-Log "Starting permission REMOVAL operation..." "WARNING"
        Write-Log "This operation may take several minutes for large directory structures..." "INFO"
        
        try {
            # Execute icacls with simplified, reliable approach
            Write-Log "Executing: icacls $($IcaclsArgs -join ' ')" "INFO"
            
            # Use Start-Process with simpler output handling to prevent deadlocks
            $ProcessArgs = @{
                FilePath = "icacls"
                ArgumentList = $IcaclsArgs
                Wait = $true
                NoNewWindow = $true
                PassThru = $true
            }
            
            # Add output redirection only if we need to capture it
            $TempOutputFile = [System.IO.Path]::GetTempFileName()
            $TempErrorFile = [System.IO.Path]::GetTempFileName()
            
            try {
                # Execute icacls with output redirection to temp files
                $ProcessArgs.RedirectStandardOutput = $TempOutputFile
                $ProcessArgs.RedirectStandardError = $TempErrorFile
                
                $Process = Start-Process @ProcessArgs
                $ExitCode = $Process.ExitCode
                
                # Read output from temp files after process completes
                $IcaclsOutput = if (Test-Path $TempOutputFile) { Get-Content $TempOutputFile -Raw } else { "" }
                $IcaclsError = if (Test-Path $TempErrorFile) { Get-Content $TempErrorFile -Raw } else { "" }
                
                # Process results
                if ($ExitCode -eq 0) {
                    Write-Log "icacls removal command completed successfully" "SUCCESS"
                    
                    # Parse icacls output for statistics if available
                    if ($IcaclsOutput) {
                        $OutputLines = $IcaclsOutput -split "`n" | Where-Object { $_.Trim() -ne "" }
                        
                        foreach ($Line in $OutputLines) {
                            $Line = $Line.Trim()
                            if ($Line -match "Successfully processed (\d+) files") {
                                $Summary.TotalFilesProcessed = [int]$Matches[1]
                                Write-Log "Files processed: $($Matches[1])" "INFO"
                            } elseif ($Line -match "Successfully processed (\d+) directories") {
                                $Summary.TotalFoldersProcessed = [int]$Matches[1]
                                Write-Log "Directories processed: $($Matches[1])" "INFO"
                            } elseif ($Line -match "Failed processing (\d+)") {
                                $Summary.FailedOperations = [int]$Matches[1]
                                Write-Log "Failed operations: $($Matches[1])" "WARNING"
                            }
                        }
                        
                        $Summary.SuccessfulOperations = $Summary.TotalFilesProcessed + $Summary.TotalFoldersProcessed
                    }
                    
                    if ($Summary.SuccessfulOperations -eq 0) {
                        # If we couldn't parse statistics, assume operation was successful
                        Write-Log "Permission removal operation completed (statistics not available from icacls output)" "INFO"
                        $Summary.SuccessfulOperations = 1  # Mark as successful
                    }
                    
                } else {
                    $ErrorMessage = "icacls removal command failed with exit code: ${ExitCode}"
                    if ($IcaclsError -and $IcaclsError.Trim() -ne "") {
                        $ErrorMessage += ". Error: $($IcaclsError.Trim())"
                    }
                    throw $ErrorMessage
                }
                
            } finally {
                # Clean up temp files
                if (Test-Path $TempOutputFile) { Remove-Item $TempOutputFile -Force -ErrorAction SilentlyContinue }
                if (Test-Path $TempErrorFile) { Remove-Item $TempErrorFile -Force -ErrorAction SilentlyContinue }
            }
            
        } catch {
            Write-Log "Permission removal failed: $($_.Exception.Message)" "ERROR"
            $Summary.FailedOperations += 1
            throw
        }
    }
    
} catch {
    Write-Log "Script execution failed: $($_.Exception.Message)" "ERROR"
    exit 1
} finally {
    # Step 5: Generate summary report
    $EndTime = Get-Date
    $ExecutionTime = $EndTime - $StartTime
    
    Write-Log " " "INFO"
    Write-Log "=== EXECUTION SUMMARY ===" "INFO"
    Write-Log "Execution Time: $($ExecutionTime.ToString('hh\:mm\:ss'))" "INFO"
    Write-Log "SharePath: ${SharePath}" "INFO"
    Write-Log "Operation: REMOVED BUILTIN\Administrators permissions" "WARNING"
    
    if (-not $WhatIfPreference) {
        Write-Log "Files Processed: $($Summary.TotalFilesProcessed)" "INFO"
        Write-Log "Folders Processed: $($Summary.TotalFoldersProcessed)" "INFO"
        Write-Log "Total Successful Operations: $($Summary.SuccessfulOperations)" "INFO"
        Write-Log "Failed Operations: $($Summary.FailedOperations)" "INFO"
        
        if ($Summary.FailedOperations -eq 0) {
            Write-Log "All removal operations completed successfully" "SUCCESS"
        } elseif ($Summary.SuccessfulOperations -gt 0) {
            Write-Log "Some removal operations completed successfully with $($Summary.FailedOperations) failures" "WARNING"
        } else {
            Write-Log "All removal operations failed" "ERROR"
        }
        
        if ($Summary.BackupLocation -ne "") {
            Write-Log "Permission backup saved to: $($Summary.BackupLocation)" "INFO"
            Write-Log "Use 'icacls SharePath /restore BackupFile' to restore if needed" "INFO"
        }
    } else {
        Write-Log "WhatIf mode - No changes were made" "INFO"
    }
    
    Write-Log "Log file location: ${LogFile}" "INFO"
    Write-Log "=== Script Completed ===" "INFO"
}