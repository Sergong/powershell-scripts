<#
.SYNOPSIS
    Configures ONTAP CIFS home directory search paths for dynamic shares
.DESCRIPTION
    Standalone utility to add, verify, or manage CIFS home directory search paths.
    This is useful for troubleshooting dynamic home directory share issues.
.PARAMETER ClusterName
    ONTAP cluster management LIF or name
.PARAMETER SVMName
    Storage Virtual Machine name
.PARAMETER SearchPath
    Home directory search path (e.g., /volume_name/users)
.PARAMETER ListOnly
    Only list current search paths without making changes
.PARAMETER Force
    Force add the search path even if it already exists
.PARAMETER Remove
    Remove the specified search path instead of adding it
.EXAMPLE
    .\Set-CIFSHomeDirSearchPath.ps1 -ClusterName "cluster1.company.com" -SVMName "svm_cifs" -SearchPath "/user_homes/users"
.EXAMPLE
    .\Set-CIFSHomeDirSearchPath.ps1 -ClusterName "cluster1.company.com" -SVMName "svm_cifs" -ListOnly
.EXAMPLE
    .\Set-CIFSHomeDirSearchPath.ps1 -ClusterName "cluster1.company.com" -SVMName "svm_cifs" -SearchPath "/user_homes/users" -Remove
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterName,
    
    [Parameter(Mandatory=$true)]
    [string]$SVMName,
    
    [Parameter(Mandatory=$false)]
    [string]$SearchPath,
    
    [Parameter(Mandatory=$false)]
    [switch]$ListOnly,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force,
    
    [Parameter(Mandatory=$false)]
    [switch]$Remove
)

#Requires -Modules DataONTAP

# Import NetApp ONTAP PowerShell Toolkit
Import-Module DataONTAP -ErrorAction Stop

# Function to log output with timestamp
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $(
        switch($Level) {
            "ERROR" { "Red" }
            "WARNING" { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
    )
}

try {
    # Connect to ONTAP Cluster
    Write-Log "Connecting to ONTAP cluster: $ClusterName"
    $Credential = Get-Credential -Message "Enter ONTAP cluster credentials"
    $Controller = Connect-NcController -Name $ClusterName -Credential $Credential -ErrorAction Stop
    Write-Log "Successfully connected to cluster: $ClusterName" -Level "SUCCESS"

    # Verify SVM exists
    Write-Log "Verifying SVM: $SVMName"
    $SVM = Get-NcVserver -Name $SVMName -ErrorAction SilentlyContinue
    if (-not $SVM) {
        Write-Log "SVM $SVMName not found!" -Level "ERROR"
        exit 1
    }
    
    # Check CIFS server status
    $CIFSServer = Get-NcCifsServer -VserverContext $SVMName -ErrorAction SilentlyContinue
    if (-not $CIFSServer) {
        Write-Log "CIFS server not configured on SVM $SVMName!" -Level "ERROR"
        exit 1
    }
    Write-Log "SVM $SVMName and CIFS server verified" -Level "SUCCESS"

    # Get current search paths
    Write-Log "Retrieving current home directory search paths"
    $CurrentSearchPaths = Get-NcCifsHomeDirSearchPath -Vserver $SVMName -ErrorAction SilentlyContinue
    
    # Display current search paths
    Write-Host "`n=== Current Home Directory Search Paths ===" -ForegroundColor Cyan
    if ($CurrentSearchPaths) {
        $pathIndex = 1
        foreach ($path in $CurrentSearchPaths) {
            Write-Host "  $pathIndex. $($path.Path)" -ForegroundColor White
            $pathIndex++
        }
    } else {
        Write-Host "  No search paths currently configured" -ForegroundColor Yellow
    }
    Write-Host ""

    # If ListOnly is specified, exit here
    if ($ListOnly) {
        Write-Log "List-only mode specified. Exiting." -Level "INFO"
        exit 0
    }

    # Validate SearchPath parameter for add/remove operations
    if (-not $SearchPath) {
        Write-Log "SearchPath parameter required for add/remove operations" -Level "ERROR"
        Write-Log "Use -ListOnly to only view current search paths" -Level "INFO"
        exit 1
    }

    # Remove search path
    if ($Remove) {
        Write-Log "Attempting to remove search path: $SearchPath"
        $ExistingPath = $CurrentSearchPaths | Where-Object { $_.Path -eq $SearchPath }
        
        if ($ExistingPath) {
            try {
                Remove-NcCifsHomeDirSearchPath -Path $SearchPath -Vserver $SVMName -ErrorAction Stop
                Write-Log "Search path removed successfully: $SearchPath" -Level "SUCCESS"
            } catch {
                Write-Log "Failed to remove search path: $($_.Exception.Message)" -Level "ERROR"
                exit 1
            }
        } else {
            Write-Log "Search path not found: $SearchPath" -Level "WARNING"
        }
        exit 0
    }

    # Add search path
    Write-Log "Processing search path: $SearchPath"
    $SearchPathExists = $CurrentSearchPaths | Where-Object { $_.Path -eq $SearchPath }
    
    if ($SearchPathExists -and -not $Force) {
        Write-Log "Search path already exists: $SearchPath" -Level "WARNING"
        Write-Log "Use -Force to reconfigure if needed" -Level "INFO"
    } else {
        try {
            if ($SearchPathExists -and $Force) {
                Write-Log "Force mode: Reconfiguring existing search path"
            }
            
            Write-Log "Adding home directory search path: $SearchPath"
            Add-NcCifsHomeDirSearchPath -Path $SearchPath -Vserver $SVMName -ErrorAction Stop
            Write-Log "Search path configured successfully: $SearchPath" -Level "SUCCESS"
            
            # Verify the search path was added
            Start-Sleep -Seconds 2  # Brief pause for ONTAP to process
            $VerifySearchPaths = Get-NcCifsHomeDirSearchPath -Vserver $SVMName -ErrorAction Stop
            $NewSearchPath = $VerifySearchPaths | Where-Object { $_.Path -eq $SearchPath }
            
            if ($NewSearchPath) {
                Write-Log "Verification successful: Search path is active" -Level "SUCCESS"
            } else {
                Write-Log "Verification failed: Search path may not be active" -Level "WARNING"
            }
            
        } catch {
            Write-Log "Failed to add search path: $($_.Exception.Message)" -Level "ERROR"
            
            # Provide troubleshooting information
            Write-Host "`nTroubleshooting Information:" -ForegroundColor Yellow
            Write-Host "1. Verify the volume path exists: $SearchPath" -ForegroundColor White
            Write-Host "2. Ensure the path uses forward slashes (Unix-style)" -ForegroundColor White
            Write-Host "3. Verify SVM has proper CIFS configuration" -ForegroundColor White
            Write-Host "4. Check ONTAP version compatibility" -ForegroundColor White
            
            exit 1
        }
    }

    # Display final state
    Write-Host "`n=== Final Home Directory Search Paths ===" -ForegroundColor Green
    $FinalSearchPaths = Get-NcCifsHomeDirSearchPath -Vserver $SVMName -ErrorAction SilentlyContinue
    if ($FinalSearchPaths) {
        $pathIndex = 1
        foreach ($path in $FinalSearchPaths) {
            $highlight = if ($path.Path -eq $SearchPath) { "Green" } else { "White" }
            Write-Host "  $pathIndex. $($path.Path)" -ForegroundColor $highlight
            $pathIndex++
        }
    }
    
    Write-Log "Home directory search path configuration completed successfully!" -Level "SUCCESS"
    
} catch {
    Write-Log "Script failed: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    exit 1
} finally {
    # Cleanup connection
    if ($Controller) {
        Write-Log "Disconnecting from ONTAP cluster"
    }
}