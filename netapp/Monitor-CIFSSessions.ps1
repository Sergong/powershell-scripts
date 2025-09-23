#Requires -Modules NetApp.ONTAP

<#
.SYNOPSIS
    Continuously monitors CIFS session information for all SVMs on a NetApp ONTAP cluster.

.DESCRIPTION
    This script runs in a loop and collects CIFS session information for each SVM on a specified 
    NetApp ONTAP cluster. The session details are saved to a timestamped CSV file with comprehensive 
    logging. The script includes proper error handling and graceful shutdown capabilities.

.PARAMETER Cluster
    The NetApp ONTAP cluster hostname or IP address to monitor.

.PARAMETER Credential
    PSCredential object for cluster authentication. If not provided, you will be prompted.

.PARAMETER OutputPath
    Directory path where CSV files and logs will be saved. Defaults to current directory.

.PARAMETER IntervalSeconds
    Time interval in seconds between monitoring cycles. Default is 300 seconds (5 minutes).

.PARAMETER MaxIterations
    Maximum number of monitoring iterations. Set to 0 for infinite loop. Default is 0.

.PARAMETER TrackUniqueSessions
    When enabled, only saves new or changed sessions to CSV, preventing duplicates.
    Default is $true to avoid CSV bloat.

.EXAMPLE
    .\Monitor-CIFSSessions-Fixed.ps1 -Cluster "cluster01.domain.com" -IntervalSeconds 180

.EXAMPLE
    .\Monitor-CIFSSessions-Fixed.ps1 -Cluster "10.1.1.100" -OutputPath "C:\Monitoring" -MaxIterations 20

.EXAMPLE
    .\Monitor-CIFSSessions-Fixed.ps1 -Cluster "cluster01.domain.com" -TrackUniqueSessions $false

.NOTES
    Author: PowerShell Scripts Repository
    Version: 1.0
    Requires: NetApp.ONTAP PowerShell Module
    
    The script creates timestamped CSV files with the naming pattern:
    CIFS_Sessions_<cluster>_<timestamp>.csv
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Cluster,
    
    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path,
    
    [Parameter(Mandatory = $false)]
    [int]$IntervalSeconds = 300,
    
    [Parameter(Mandatory = $false)]
    [int]$MaxIterations = 0,
    
    [Parameter(Mandatory = $false)]
    [bool]$TrackUniqueSessions = $true
)

# Global variables
$script:LogFile = ""
$script:CurrentCsvFile = ""
$script:IterationCount = 0
$script:StartTime = Get-Date
$script:TrackedSessions = @{}  # Hash table to track unique sessions

# Function to write log messages
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    
    # Write to console with color coding
    switch ($Level) {
        "ERROR" { Write-Host $LogEntry -ForegroundColor Red }
        "WARNING" { Write-Host $LogEntry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $LogEntry -ForegroundColor Green }
        default { Write-Host $LogEntry -ForegroundColor White }
    }
    
    # Write to log file if not in WhatIf mode
    if (-not $WhatIfPreference -and $script:LogFile) {
        Add-Content -Path $script:LogFile -Value $LogEntry
    }
}

# Function to initialize output files
function Initialize-OutputFiles {
    try {
        # Create output directory if it doesn't exist
        if (-not (Test-Path $OutputPath)) {
            if ($WhatIfPreference) {
                Write-Log "Would create directory: $OutputPath" "INFO"
            } else {
                New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
                Write-Log "Created output directory: $OutputPath" "SUCCESS"
            }
        }
        
        # Generate timestamped filenames
        $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $ClusterName = ($Cluster -split '\.')[0]  # Use first part of FQDN
        
        $script:LogFile = Join-Path $OutputPath "Monitor_CIFSSessions_${ClusterName}_$Timestamp.log"
        $script:CurrentCsvFile = Join-Path $OutputPath "CIFS_Sessions_${ClusterName}_$Timestamp.csv"
        
        if ($WhatIfPreference) {
            Write-Log "Would create log file: $($script:LogFile)" "INFO"
            Write-Log "Would create CSV file: $($script:CurrentCsvFile)" "INFO"
        } else {
            # Create initial log entry
            Write-Log "CIFS Session Monitoring Started" "SUCCESS"
            Write-Log "Cluster: $Cluster" "INFO"
            Write-Log "Output Path: $OutputPath" "INFO"
            Write-Log "Interval: $IntervalSeconds seconds" "INFO"
            Write-Log "Max Iterations: $(if ($MaxIterations -eq 0) { 'Infinite' } else { $MaxIterations })" "INFO"
            Write-Log "Track Unique Sessions: $TrackUniqueSessions" "INFO"
        }
        
        return $true
    }
    catch {
        Write-Log "Failed to initialize output files: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Function to collect CIFS session information
function Get-CIFSSessionData {
    try {
        Write-Log "Collecting CIFS session data for all SVMs..." "INFO"
        
        # Get all data SVMs with CIFS protocol enabled
        $SVMs = Get-NcVserver | Where-Object { 
            # Filter for data SVMs only (exclude admin, system, node SVMs)
            $IsDataSVM = $false
            try {
                $IsDataSVM = $_.VserverType -eq "data"
            } catch {
                # Fallback: if VserverType doesn't exist, assume it's a data SVM
                $IsDataSVM = $true
            }
            
            # Handle AllowedProtocols as array properly
            $HasCifs = $false
            try {
                if ($_.AllowedProtocols) {
                    $HasCifs = $_.AllowedProtocols -contains "cifs"
                }
            } catch {
                # Fallback: try string comparison
                $HasCifs = $_.AllowedProtocols -match "cifs"
            }
            
            $IsDataSVM -and $HasCifs -and $_.State -eq "running"
        }
        
        if (-not $SVMs) {
            Write-Log "No CIFS-enabled data SVMs found on cluster $Cluster" "WARNING"
            return @()
        }
        
        $SVMCount = ($SVMs | Measure-Object).Count
        Write-Log "Found $SVMCount CIFS-enabled data SVM(s)" "INFO"
        
        # Debug: Show SVM properties for troubleshooting
        foreach ($DebugSVM in $SVMs) {
            $SVMProperties = @()
            $DebugSVM | Get-Member -MemberType Property | ForEach-Object {
                $PropName = $_.Name
                try {
                    $PropValue = $DebugSVM.$PropName
                    if ($PropValue -ne $null) {
                        # Handle arrays properly
                        if ($PropValue -is [Array] -and $PropValue.Count -gt 0) {
                            $DisplayValue = "[$($PropValue -join ',')]" 
                        } else {
                            $DisplayValue = $PropValue.ToString()
                        }
                        
                        if ($DisplayValue.Length -lt 60) {
                            $SVMProperties += "$PropName=$DisplayValue"
                        }
                    }
                } catch {
                    $SVMProperties += "$PropName=<error>"
                }
            }
            Write-Log "DEBUG SVM Properties: $($SVMProperties -join '; ')" "INFO"
        }
        
        $AllSessions = @()
        
        foreach ($SVM in $SVMs) {
            # Initialize SVM name outside try block for proper scope
            $SVMName = $null
            
            try {
                # Try multiple property names for SVM name
                $PossibleNameProperties = @('Name', 'VserverName', 'Vserver', 'VServer', 'SvmName')
                foreach ($PropName in $PossibleNameProperties) {
                    if ($SVM.$PropName -and $SVM.$PropName -ne $null) {
                        $SVMName = $SVM.$PropName
                        Write-Log "Using SVM property '$PropName' with value: $SVMName" "INFO"
                        break
                    }
                }
                
                if (-not $SVMName) {
                    Write-Log "ERROR: Could not determine SVM name from any property" "ERROR"
                    continue
                }
                
                Write-Log "Checking CIFS sessions for SVM: $SVMName" "INFO"
                
                # Get CIFS sessions for this SVM
                $Sessions = Get-NcCifsSession -VserverContext $SVMName -ErrorAction SilentlyContinue
                
                if ($Sessions) {
                    $SessionCount = ($Sessions | Measure-Object).Count
                    Write-Log "Found $SessionCount active session(s) for SVM $SVMName" "SUCCESS"
                    
                    foreach ($Session in $Sessions) {
                        $SessionData = [PSCustomObject]@{
                            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                            Cluster = $Cluster
                            SVM = $SVMName
                            SessionId = $Session.SessionId
                            ConnectionId = $Session.ConnectionId
                            ClientAddress = $Session.Address
                            ConnectedHostname = $Session.NetbiosName  # DNS CNAME/hostname used to connect
                            AuthenticatedUser = $Session.WindowsUser
                            OpenFiles = $Session.OpenFiles
                            OpenShares = $Session.OpenShares
                            IdleTime = $Session.IdleTime
                            ConnectionTime = $Session.ConnectionTime
                            Protocol = $Session.Protocol
                            ProtocolVersion = $Session.ProtocolVersion
                            LargeFileSupport = $Session.LargeMtu
                            SessionState = $Session.State
                        }
                        $AllSessions += $SessionData
                    }
                } else {
                    Write-Log "No active CIFS sessions found for SVM $SVMName" "INFO"
                    
                    # Add entry showing no sessions for this SVM
                    $NoSessionData = [PSCustomObject]@{
                        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        Cluster = $Cluster
                        SVM = $SVMName
                        SessionId = "No active sessions"
                        ConnectionId = ""
                        ClientAddress = ""
                        ConnectedHostname = ""  # DNS CNAME/hostname used to connect
                        AuthenticatedUser = ""
                        OpenFiles = 0
                        OpenShares = 0
                        IdleTime = ""
                        ConnectionTime = ""
                        Protocol = ""
                        ProtocolVersion = ""
                        LargeFileSupport = ""
                        SessionState = ""
                    }
                    $AllSessions += $NoSessionData
                }
            }
            catch {
                $SVMDisplayName = if ($SVMName) { $SVMName } else { "<unknown>" }
                $ErrorMessage = $_.Exception.Message
                Write-Log "Error collecting sessions for SVM ${SVMDisplayName}: $ErrorMessage" "ERROR"
            }
        }
        
        return $AllSessions
    }
    catch {
        Write-Log "Error collecting CIFS session data: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

# Function to filter unique sessions
function Get-UniqueSessionData {
    param(
        [array]$SessionData
    )
    
    if (-not $TrackUniqueSessions) {
        Write-Log "Session uniqueness tracking disabled - returning all sessions" "INFO"
        return $SessionData
    }
    
    $NewSessions = @()
    $CurrentIterationKeys = @()
    
    foreach ($Session in $SessionData) {
        # Create unique key for session (combination of cluster, SVM, and session ID)
        $SessionKey = "$($Session.Cluster)|$($Session.SVM)|$($Session.SessionId)"
        $CurrentIterationKeys += $SessionKey
        
        # Skip "No active sessions" entries from uniqueness tracking
        if ($Session.SessionId -eq "No active sessions") {
            # Always include "no sessions" entries but don't track them
            $NewSessions += $Session
            continue
        }
        
        # Create hash based only on core session identity (SVM, ClientAddress, SessionID)
        try {
            # Hash only the core identifying properties of the session
            $SessionIdentity = "$($Session.SVM)|$($Session.ClientAddress)|$($Session.SessionId)"
            $StringBytes = [System.Text.Encoding]::UTF8.GetBytes($SessionIdentity)
            $MD5 = [System.Security.Cryptography.MD5]::Create()
            $HashBytes = $MD5.ComputeHash($StringBytes)
            $SessionHash = [BitConverter]::ToString($HashBytes) -replace '-',''
            $MD5.Dispose()
        } catch {
            Write-Log "Error creating session hash for SessionId $($Session.SessionId): $($_.Exception.Message)" "ERROR"
            # Simple fallback hash using the same core properties
            $SessionIdentity = "$($Session.SVM)|$($Session.ClientAddress)|$($Session.SessionId)"
            # Use a simple string hash if MD5 fails
            $SessionHash = $SessionIdentity.GetHashCode().ToString()
        }
        
        # Check if this is a new session (only save new sessions, not changes or endings)
        if (-not $script:TrackedSessions.ContainsKey($SessionKey)) {
            # This is a new session - track it and save to CSV
            $script:TrackedSessions[$SessionKey] = @{
                Hash = $SessionHash
                LastSeen = Get-Date
                Data = $Session
            }
            
            $NewSessions += $Session
            Write-Log "New session detected: SVM=$($Session.SVM), SessionID=$($Session.SessionId), Client=$($Session.ClientAddress)" "SUCCESS"
        } else {
            # Session already exists - just update the LastSeen timestamp (no CSV save)
            $script:TrackedSessions[$SessionKey].LastSeen = Get-Date
        }
    }
    
    # Clean up sessions that are no longer active (not seen in current iteration)
    # Note: We still remove them from tracking but don't create CSV records for ended sessions
    $SessionsToRemove = @()
    foreach ($Key in $script:TrackedSessions.Keys) {
        if ($CurrentIterationKeys -notcontains $Key) {
            $RemovedSession = $script:TrackedSessions[$Key].Data
            Write-Log "Session ended: SVM=$($RemovedSession.SVM), SessionID=$($RemovedSession.SessionId), Client=$($RemovedSession.ClientAddress)" "INFO"
            $SessionsToRemove += $Key
        }
    }
    
    # Remove ended sessions from tracking (no CSV records created)
    foreach ($Key in $SessionsToRemove) {
        $script:TrackedSessions.Remove($Key)
    }
    
    Write-Log "New Sessions: $(($NewSessions | Measure-Object).Count) out of $(($SessionData | Measure-Object).Count) total" "INFO"
    
    return $NewSessions
}

# Function to save session data to CSV
function Save-SessionDataToCsv {
    param(
        [array]$SessionData
    )
    
    try {
        if ($SessionData -and ($SessionData.Count -gt 0)) {
            # Filter for unique sessions if tracking is enabled
            $UniqueSessionData = Get-UniqueSessionData -SessionData $SessionData
            
            if ($UniqueSessionData -and ($UniqueSessionData.Count -gt 0)) {
                if ($WhatIfPreference) {
                    Write-Log "Would save $(($UniqueSessionData | Measure-Object).Count) new session records to $($script:CurrentCsvFile)" "INFO"
                    $UniqueSessionData | Format-Table -AutoSize | Out-String | Write-Host
                } else {
                    # Check if file exists to determine if we need headers
                    $AddHeaders = -not (Test-Path $script:CurrentCsvFile)
                    
                    $UniqueSessionData | Export-Csv -Path $script:CurrentCsvFile -NoTypeInformation -Append:(-not $AddHeaders)
                    
                    Write-Log "Saved $(($UniqueSessionData | Measure-Object).Count) new session records to CSV file" "SUCCESS"
                }
            } else {
                Write-Log "No new session data to save" "INFO"
            }
        } else {
            Write-Log "No session data to process" "INFO"
        }
    }
    catch {
        Write-Log "Error saving session data to CSV: $($_.Exception.Message)" "ERROR"
    }
}

# Function to handle graceful shutdown
function Stop-Monitoring {
    Write-Log "Stopping CIFS session monitoring..." "INFO"
    Write-Log "Total iterations completed: $($script:IterationCount)" "INFO"
    Write-Log "Total unique sessions tracked: $(($script:TrackedSessions.Keys | Measure-Object).Count)" "INFO"
    $EndTime = Get-Date
    $Duration = $EndTime - $script:StartTime
    Write-Log "Total monitoring duration: $($Duration.ToString('dd\.hh\:mm\:ss'))" "INFO"
    
    # Disconnect from cluster if connected
    try {
        # Check if disconnect cmdlet is available
        if (Get-Command "Disconnect-NcController" -ErrorAction SilentlyContinue) {
            # Try to disconnect gracefully
            Disconnect-NcController -ErrorAction SilentlyContinue
            Write-Log "Disconnected from NetApp cluster" "SUCCESS"
        } else {
            # No explicit disconnect cmdlet available - connection will close when session ends
            Write-Log "NetApp cluster connection will close automatically when session ends" "INFO"
        }
    }
    catch {
        Write-Log "Warning: Could not properly disconnect from cluster: $($_.Exception.Message)" "WARNING"
    }
    
    Write-Log "CIFS Session Monitoring Stopped" "SUCCESS"
    exit 0
}

# Register event handlers for graceful shutdown
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Stop-Monitoring }
$null = [System.Console]::TreatControlCAsInput = $false

# Main execution block
try {
    Write-Host "NetApp CIFS Session Monitor" -ForegroundColor Cyan
    Write-Host "=========================" -ForegroundColor Cyan
    Write-Host ""
    
    # Initialize output files
    if (-not (Initialize-OutputFiles)) {
        exit 1
    }
    
    # Connect to NetApp cluster (always connect, even in WhatIf mode)
    Write-Log "Connecting to NetApp cluster: $Cluster" "INFO"
    
    if (-not $Credential) {
        Write-Host "Please provide credentials for NetApp cluster $Cluster" -ForegroundColor Yellow
        $Credential = Get-Credential -Message "Enter credentials for NetApp cluster $Cluster"
        if (-not $Credential) {
            Write-Log "No credentials provided. Exiting." "ERROR"
            exit 1
        }
    }
    
    Connect-NcController -Name $Cluster -Credential $Credential -ErrorAction Stop | Out-Null
    Write-Log "Successfully connected to cluster $Cluster" "SUCCESS"
    
    # Verify cluster connectivity
    $ClusterInfo = Get-NcCluster
    Write-Log "Cluster Name: $($ClusterInfo.ClusterName)" "INFO"
    Write-Log "ONTAP Version: $($ClusterInfo.ClusterVersion)" "INFO"
    
    if ($WhatIfPreference) {
        Write-Log "WhatIf mode: Will collect real session data but not write to files" "INFO"
    }
    
    # Main monitoring loop
    Write-Log "Starting monitoring loop..." "SUCCESS"
    
    while ($true) {
        try {
            $script:IterationCount++
            Write-Log "Starting iteration $($script:IterationCount)" "INFO"
            
            # Collect CIFS session data (always collect real data)
            $SessionData = Get-CIFSSessionData
            
            # Save data to CSV
            Save-SessionDataToCsv -SessionData $SessionData
            
            # Check if we've reached max iterations
            if ($MaxIterations -gt 0 -and $script:IterationCount -ge $MaxIterations) {
                Write-Log "Reached maximum iterations ($MaxIterations)" "INFO"
                break
            }
            
            # Wait for next iteration
            if ($MaxIterations -eq 0 -or $script:IterationCount -lt $MaxIterations) {
                Write-Log "Waiting $IntervalSeconds seconds before next collection..." "INFO"
                Start-Sleep -Seconds $IntervalSeconds
            }
        }
        catch {
            Write-Log "Error in monitoring iteration $($script:IterationCount): $($_.Exception.Message)" "ERROR"
            Write-Log "Continuing with next iteration..." "WARNING"
        }
    }
}
catch {
    Write-Log "Critical error in main execution: $($_.Exception.Message)" "ERROR"
    exit 1
}
finally {
    Stop-Monitoring
}