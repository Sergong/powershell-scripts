<#
.SYNOPSIS
    Recursively adds BUILTIN\Administrators group permissions to all files and folders in a share using icacls

.DESCRIPTION
    This script uses the Windows icacls command to recursively ADD BUILTIN\Administrators group 
    permissions to all files and folders within a specified share path. IMPORTANT: This script 
    PRESERVES all existing permissions and only adds the new permission entry. No existing ACL 
    entries are removed or modified. The script includes comprehensive logging, error handling, 
    optional permission backup, and WhatIf support for safe testing.
    
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

.PARAMETER Permissions
    The permission level to grant to BUILTIN\Administrators group.
    Valid values: FullControl, Modify, ReadWrite, Read
    Default: FullControl

.PARAMETER BackupOriginalPermissions
    Switch parameter to create a backup of original permissions before modification.
    The backup will be saved as an .acl file that can be restored using icacls /restore.

.PARAMETER LogPath
    Optional custom path for the log file. If not specified, logs will be created in the script directory.

.EXAMPLE
    .\Set-ShareAdministratorPermissions.ps1 -SharePath "\\fileserver\shares\data"
    
    Adds BUILTIN\Administrators full control to all files and folders in the data share.
    All existing permissions are preserved - only the new permission is added.

.EXAMPLE
    .\Set-ShareAdministratorPermissions.ps1 -SharePath "C:\CompanyData" -WhatIf
    
    Shows what would be done without making any actual changes (safe testing mode).

.EXAMPLE
    .\Set-ShareAdministratorPermissions.ps1 -SharePath "\\server\share" -Permissions "Modify" -BackupOriginalPermissions
    
    Grants Modify permissions to BUILTIN\Administrators after backing up original permissions.

.NOTES
    Requirements:
    - Windows operating system (icacls command)
    - PowerShell 5.1 or later
    - Administrator privileges for modifying permissions
    - Network connectivity for UNC paths
    
    Permission Codes Used:
    - FullControl: (OI)(CI)F (Object Inherit, Container Inherit, Full Control)
    - Modify: (OI)(CI)M 
    - ReadWrite: (OI)(CI)RW
    - Read: (OI)(CI)R
    
    icacls Flags Used:
    - /grant - Add new permissions while preserving existing ACL entries
    - /t - Apply recursively to all files and subdirectories  
    - /c - Continue operation even if errors occur
    - (OI)(CI) - Object and Container Inherit for files and folders

.LINK
    Based on PowerShell coding standards defined in WARP.md
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$true, Position=0, HelpMessage="UNC path or local path to process")]
    [ValidateNotNullOrEmpty()]
    [string]$SharePath,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("FullControl", "Modify", "ReadWrite", "Read")]
    [string]$Permissions = "FullControl",
    
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
    $LogFile = Join-Path $ScriptDirectory "Set-ShareAdminPerms_${Timestamp}.log"
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

# Permission mapping for icacls
$PermissionMap = @{
    "FullControl" = "F"
    "Modify"     = "M"
    "ReadWrite"  = "RW"
    "Read"       = "R"
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

Write-Log "=== Share Administrator Permissions Script Started ===" "INFO"
Write-Log "SharePath: ${SharePath}" "INFO"
Write-Log "Permissions: ${Permissions}" "INFO"
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
                
                # Use Start-Process for better error handling and output capture
                $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
                $ProcessInfo.FileName = "icacls"
                $ProcessInfo.Arguments = $BackupArgs -join " "
                $ProcessInfo.UseShellExecute = $false
                $ProcessInfo.RedirectStandardOutput = $true
                $ProcessInfo.RedirectStandardError = $true
                $ProcessInfo.CreateNoWindow = $true
                
                $Process = New-Object System.Diagnostics.Process
                $Process.StartInfo = $ProcessInfo
                $Process.Start() | Out-Null
                $BackupOutput = $Process.StandardOutput.ReadToEnd()
                $BackupError = $Process.StandardError.ReadToEnd()
                $Process.WaitForExit()
                
                if ($Process.ExitCode -eq 0) {
                    Write-Log "Permissions backup created successfully: ${BackupFile}" "SUCCESS"
                    if ($BackupOutput) {
                        Write-Log "Backup output: $BackupOutput" "INFO"
                    }
                } else {
                    $ErrorMessage = if ($BackupError) { $BackupError } else { "Exit code: $($Process.ExitCode)" }
                    Write-Log "Permission backup failed but continuing: $ErrorMessage" "WARNING"
                }
            } catch {
                Write-Log "Permission backup failed but continuing: $($_.Exception.Message)" "WARNING"
            }
        }
    }
    
    # Step 3: Prepare icacls command
    $PermissionCode = $PermissionMap[$Permissions]
    $GrantExpression = "BUILTIN\Administrators:(OI)(CI)${PermissionCode}"
    
    Write-Log "Preparing to grant permissions: ${GrantExpression}" "INFO"
    
    $IcaclsArgs = @(
        "`"${SharePath}`"",
        "/grant",
        "`"${GrantExpression}`"",
        "/t",
        "/c"
    )
    
    if ($WhatIfPreference) {
        Write-Log "[WHATIF] Would execute: icacls $($IcaclsArgs -join ' ')" "INFO"
        Write-Log "[WHATIF] Flags explanation:" "INFO"
        Write-Log "[WHATIF]   /grant - ADD permissions while preserving existing ACLs" "INFO"
        Write-Log "[WHATIF]   /t - Apply recursively to all files and subdirectories" "INFO"
        Write-Log "[WHATIF]   /c - Continue operation even if errors occur" "INFO"
        Write-Log "[WHATIF] This would recursively grant ${Permissions} permissions to BUILTIN\Administrators" "INFO"
        Write-Log "[WHATIF] No changes will be made in WhatIf mode" "INFO"
    } else {
        # Step 4: Execute icacls command with progress indication
        Write-Log "Starting permission modification..." "INFO"
        Write-Log "This may take a while for large directory structures..." "INFO"
        
        try {
            # Execute icacls with proper PowerShell error handling
            Write-Log "Executing: icacls $($IcaclsArgs -join ' ')" "INFO"
            
            # Use Start-Process for reliable cross-platform execution and output capture
            $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
            $ProcessInfo.FileName = "icacls"
            $ProcessInfo.Arguments = $IcaclsArgs -join " "
            $ProcessInfo.UseShellExecute = $false
            $ProcessInfo.RedirectStandardOutput = $true
            $ProcessInfo.RedirectStandardError = $true
            $ProcessInfo.CreateNoWindow = $true
            
            $Process = New-Object System.Diagnostics.Process
            $Process.StartInfo = $ProcessInfo
            $Process.Start() | Out-Null
            
            # Read output while process is running to avoid deadlocks
            $OutputBuilder = New-Object System.Text.StringBuilder
            $ErrorBuilder = New-Object System.Text.StringBuilder
            
            # Create async readers for stdout and stderr
            $OutputReader = $Process.StandardOutput
            $ErrorReader = $Process.StandardError
            
            # Read all output
            while (!$Process.HasExited -or !$OutputReader.EndOfStream -or !$ErrorReader.EndOfStream) {
                if (!$OutputReader.EndOfStream) {
                    $Line = $OutputReader.ReadLine()
                    if ($Line -ne $null) {
                        [void]$OutputBuilder.AppendLine($Line)
                    }
                }
                if (!$ErrorReader.EndOfStream) {
                    $ErrorLine = $ErrorReader.ReadLine()
                    if ($ErrorLine -ne $null) {
                        [void]$ErrorBuilder.AppendLine($ErrorLine)
                    }
                }
                Start-Sleep -Milliseconds 50
            }
            
            $Process.WaitForExit()
            $IcaclsOutput = $OutputBuilder.ToString()
            $IcaclsError = $ErrorBuilder.ToString()
            $ExitCode = $Process.ExitCode
            
            # Process results
            if ($ExitCode -eq 0) {
                Write-Log "icacls command completed successfully" "SUCCESS"
                
                # Parse icacls output for statistics
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
                
                # Log any additional output
                if ($IcaclsOutput -and $IcaclsOutput.Trim() -ne "") {
                    Write-Log "icacls output: $($IcaclsOutput.Trim())" "INFO"
                }
                
            } else {
                $ErrorMessage = "icacls command failed with exit code: ${ExitCode}"
                if ($IcaclsError -and $IcaclsError.Trim() -ne "") {
                    $ErrorMessage += ". Error: $($IcaclsError.Trim())"
                }
                if ($IcaclsOutput -and $IcaclsOutput.Trim() -ne "") {
                    $ErrorMessage += ". Output: $($IcaclsOutput.Trim())"
                }
                throw $ErrorMessage
            }
            
        } catch {
            Write-Log "Permission modification failed: $($_.Exception.Message)" "ERROR"
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
    Write-Log "Permissions Granted: ${Permissions} to BUILTIN\Administrators" "INFO"
    
    if (-not $WhatIfPreference) {
        Write-Log "Files Processed: $($Summary.TotalFilesProcessed)" "INFO"
        Write-Log "Folders Processed: $($Summary.TotalFoldersProcessed)" "INFO"
        Write-Log "Total Successful Operations: $($Summary.SuccessfulOperations)" "INFO"
        Write-Log "Failed Operations: $($Summary.FailedOperations)" "INFO"
        
        if ($Summary.FailedOperations -eq 0) {
            Write-Log "All operations completed successfully" "SUCCESS"
        } elseif ($Summary.SuccessfulOperations -gt 0) {
            Write-Log "Some operations completed successfully with $($Summary.FailedOperations) failures" "WARNING"
        } else {
            Write-Log "All operations failed" "ERROR"
        }
        
        if ($Summary.BackupLocation -ne "") {
            Write-Log "Permission backup saved to: $($Summary.BackupLocation)" "INFO"
        }
    } else {
        Write-Log "WhatIf mode - No changes were made" "INFO"
    }
    
    Write-Log "Log file location: ${LogFile}" "INFO"
    Write-Log "=== Script Completed ===" "INFO"
}