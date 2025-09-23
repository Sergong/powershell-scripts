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

.PARAMETER WhatIf
    Shows what would be done without actually connecting to the cluster or creating files.

.EXAMPLE
    .\Monitor-CIFSSessions.ps1 -Cluster "cluster01.domain.com" -IntervalSeconds 180

.EXAMPLE
    .\Monitor-CIFSSessions.ps1 -Cluster "10.1.1.100" -OutputPath "C:\Monitoring" -MaxIterations 20

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
    [string]${Cluster},
    
    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]${Credential},
    
    [Parameter(Mandatory = $false)]
    [string]${OutputPath} = (Get-Location).Path,
    
    [Parameter(Mandatory = $false)]
    [int]${IntervalSeconds} = 300,
    
    [Parameter(Mandatory = $false)]
    [int]${MaxIterations} = 0,
    
    [switch]${WhatIf}
)

# Global variables
${script:LogFile} = ""
${script:CurrentCsvFile} = ""
${script:IterationCount} = 0
${script:StartTime} = Get-Date

# Function to write log messages
function Write-Log {
    param(
        [string]${Message},
        [string]${Level} = "INFO"
    )
    
    ${Timestamp} = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    ${LogEntry} = "[${Timestamp}] [${Level}] ${Message}"
    
    # Write to console with color coding
    switch (${Level}) {
        "ERROR" { Write-Host ${LogEntry} -ForegroundColor Red }
        "WARNING" { Write-Host ${LogEntry} -ForegroundColor Yellow }
        "SUCCESS" { Write-Host ${LogEntry} -ForegroundColor Green }
        default { Write-Host ${LogEntry} -ForegroundColor White }
    }
    
    # Write to log file if not in WhatIf mode
    if (-not ${WhatIf} -and ${script:LogFile}) {
        Add-Content -Path ${script:LogFile} -Value ${LogEntry}
    }
}

# Function to initialize output files
function Initialize-OutputFiles {
    try {
        # Create output directory if it doesn't exist
        if (-not (Test-Path ${OutputPath})) {
            if (${WhatIf}) {
                Write-Log "Would create directory: ${OutputPath}" "INFO"
            } else {
                New-Item -Path ${OutputPath} -ItemType Directory -Force | Out-Null
                Write-Log "Created output directory: ${OutputPath}" "SUCCESS"
            }
        }
        
        # Generate timestamped filenames
        ${Timestamp} = Get-Date -Format "yyyyMMdd_HHmmss"
        ${ClusterName} = (${Cluster} -split '\.')[0]  # Use first part of FQDN
        
        ${script:LogFile} = Join-Path ${OutputPath} "Monitor_CIFSSessions_${ClusterName}_${Timestamp}.log"
        ${script:CurrentCsvFile} = Join-Path ${OutputPath} "CIFS_Sessions_${ClusterName}_${Timestamp}.csv"
        
        if (${WhatIf}) {
            Write-Log "Would create log file: ${script:LogFile}" "INFO"
            Write-Log "Would create CSV file: ${script:CurrentCsvFile}" "INFO"
        } else {
            # Create initial log entry
            Write-Log "CIFS Session Monitoring Started" "SUCCESS"
            Write-Log "Cluster: ${Cluster}" "INFO"
            Write-Log "Output Path: ${OutputPath}" "INFO"
            Write-Log "Interval: ${IntervalSeconds} seconds" "INFO"
            Write-Log "Max Iterations: $(if (${MaxIterations} -eq 0) { 'Infinite' } else { ${MaxIterations} })" "INFO"
        }
        
        return $true
    }
    catch {
        Write-Log "Failed to initialize output files: ${_}" "ERROR"
        return $false
    }
}

# Function to collect CIFS session information
function Get-CIFSSessionData {
    try {
        Write-Log "Collecting CIFS session data for all SVMs..." "INFO"
        
        # Get all SVMs with CIFS protocol enabled
        ${SVMs} = Get-NcVserver | Where-Object { 
            ${_.AllowedProtocols} -contains "cifs" -and ${_.State} -eq "running" 
        }
        
        if (-not ${SVMs}) {
            Write-Log "No CIFS-enabled SVMs found on cluster ${Cluster}" "WARNING"
            return @()
        }
        
        Write-Log "Found $((${SVMs} | Measure-Object).Count) CIFS-enabled SVM(s)" "INFO"
        
        ${AllSessions} = @()
        
        foreach (${SVM} in ${SVMs}) {
            try {
                Write-Log "Checking CIFS sessions for SVM: ${SVM}.Name" "INFO"
                
                # Get CIFS sessions for this SVM
                ${Sessions} = Get-NcCifsSession -VserverContext ${SVM}.Name -ErrorAction SilentlyContinue
                
                if (${Sessions}) {
                    Write-Log "Found $((${Sessions} | Measure-Object).Count) active session(s) for SVM ${SVM}.Name" "SUCCESS"
                    
                    foreach (${Session} in ${Sessions}) {
                        ${SessionData} = [PSCustomObject]@{
                            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                            Cluster = ${Cluster}
                            SVM = ${SVM}.Name
                            SessionId = ${Session}.SessionId
                            ConnectionId = ${Session}.ConnectionId
                            ClientAddress = ${Session}.Address
                            ClientName = ${Session}.NetbiosName
                            AuthenticatedUser = ${Session}.WindowsUser
                            OpenFiles = ${Session}.OpenFiles
                            OpenShares = ${Session}.OpenShares
                            IdleTime = ${Session}.IdleTime
                            ConnectionTime = ${Session}.ConnectionTime
                            Protocol = ${Session}.Protocol
                            ProtocolVersion = ${Session}.ProtocolVersion
                            LargeFileSupport = ${Session}.LargeMtu
                            SessionState = ${Session}.State
                        }
                        ${AllSessions} += ${SessionData}
                    }
                } else {
                    Write-Log "No active CIFS sessions found for SVM ${SVM}.Name" "INFO"
                    
                    # Add entry showing no sessions for this SVM
                    ${NoSessionData} = [PSCustomObject]@{
                        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        Cluster = ${Cluster}
                        SVM = ${SVM}.Name
                        SessionId = "No active sessions"
                        ConnectionId = ""
                        ClientAddress = ""
                        ClientName = ""
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
                    ${AllSessions} += ${NoSessionData}
                }
            }
            catch {
                Write-Log "Error collecting sessions for SVM ${SVM}.Name: ${_}" "ERROR"
            }
        }
        
        return ${AllSessions}
    }
    catch {
        Write-Log "Error collecting CIFS session data: ${_}" "ERROR"
        return @()
    }
}

# Function to save session data to CSV
function Save-SessionDataToCsv {
    param(
        [array]${SessionData}
    )
    
    try {
        if (${SessionData} -and (${SessionData}.Count -gt 0)) {
            if (${WhatIf}) {
                Write-Log "Would save $((${SessionData} | Measure-Object).Count) session records to ${script:CurrentCsvFile}" "INFO"
                ${SessionData} | Format-Table -AutoSize | Out-String | Write-Host
            } else {
                # Check if file exists to determine if we need headers
                ${AddHeaders} = -not (Test-Path ${script:CurrentCsvFile})
                
                ${SessionData} | Export-Csv -Path ${script:CurrentCsvFile} -NoTypeInformation -Append:(-not ${AddHeaders})
                
                Write-Log "Saved $((${SessionData} | Measure-Object).Count) session records to CSV file" "SUCCESS"
            }
        } else {
            Write-Log "No session data to save" "INFO"
        }
    }
    catch {
        Write-Log "Error saving session data to CSV: ${_}" "ERROR"
    }
}

# Function to handle graceful shutdown
function Stop-Monitoring {
    Write-Log "Stopping CIFS session monitoring..." "INFO"
    Write-Log "Total iterations completed: ${script:IterationCount}" "INFO"
    ${EndTime} = Get-Date
    ${Duration} = ${EndTime} - ${script:StartTime}
    Write-Log "Total monitoring duration: $((${Duration}.ToString('dd\.hh\:mm\:ss')))" "INFO"
    
    # Disconnect from cluster if connected
    try {
        ${Connection} = Get-NcController -ErrorAction SilentlyContinue
        if (${Connection}) {
            Disconnect-NcController -ErrorAction SilentlyContinue
            Write-Log "Disconnected from NetApp cluster" "SUCCESS"
        }
    }
    catch {
        Write-Log "Error during cleanup: ${_}" "WARNING"
    }
    
    Write-Log "CIFS Session Monitoring Stopped" "SUCCESS"
    exit 0
}

# Register event handlers for graceful shutdown
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Stop-Monitoring }
${null} = [System.Console]::TreatControlCAsInput = $false

# Main execution block
try {
    Write-Host "NetApp CIFS Session Monitor" -ForegroundColor Cyan
    Write-Host "=========================" -ForegroundColor Cyan
    Write-Host ""
    
    # Initialize output files
    if (-not (Initialize-OutputFiles)) {
        exit 1
    }
    
    # Connect to NetApp cluster
    if (${WhatIf}) {
        Write-Log "Would connect to NetApp cluster: ${Cluster}" "INFO"
    } else {
        Write-Log "Connecting to NetApp cluster: ${Cluster}" "INFO"
        
        if (-not ${Credential}) {
            ${Credential} = Get-Credential -Message "Enter credentials for NetApp cluster ${Cluster}"
        }
        
        Connect-NcController -Name ${Cluster} -Credential ${Credential} -ErrorAction Stop | Out-Null
        Write-Log "Successfully connected to cluster ${Cluster}" "SUCCESS"
        
        # Verify cluster connectivity
        ${ClusterInfo} = Get-NcCluster
        Write-Log "Cluster Name: $((${ClusterInfo}.ClusterName))" "INFO"
        Write-Log "ONTAP Version: $((${ClusterInfo}.ClusterVersion))" "INFO"
    }
    
    # Main monitoring loop
    Write-Log "Starting monitoring loop..." "SUCCESS"
    
    while (${true}) {
        try {
            ${script:IterationCount}++
            Write-Log "Starting iteration ${script:IterationCount}" "INFO"
            
            # Collect CIFS session data
            ${SessionData} = if (${WhatIf}) { 
                @([PSCustomObject]@{
                    Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    Cluster = ${Cluster}
                    SVM = "example_svm"
                    SessionId = "12345"
                    ConnectionId = "67890"
                    ClientAddress = "192.168.1.100"
                    ClientName = "CLIENT01"
                    AuthenticatedUser = "DOMAIN\user1"
                    OpenFiles = 5
                    OpenShares = 2
                    IdleTime = "00:15:30"
                    ConnectionTime = "02:45:12"
                    Protocol = "SMB"
                    ProtocolVersion = "3.1.1"
                    LargeFileSupport = $true
                    SessionState = "Active"
                })
            } else { 
                Get-CIFSSessionData 
            }
            
            # Save data to CSV
            Save-SessionDataToCsv -SessionData ${SessionData}
            
            # Check if we've reached max iterations
            if (${MaxIterations} -gt 0 -and ${script:IterationCount} -ge ${MaxIterations}) {
                Write-Log "Reached maximum iterations (${MaxIterations})" "INFO"
                break
            }
            
            # Wait for next iteration
            if (${MaxIterations} -eq 0 -or ${script:IterationCount} -lt ${MaxIterations}) {
                Write-Log "Waiting ${IntervalSeconds} seconds before next collection..." "INFO"
                Start-Sleep -Seconds ${IntervalSeconds}
            }
        }
        catch {
            Write-Log "Error in monitoring iteration ${script:IterationCount}: ${_}" "ERROR"
            Write-Log "Continuing with next iteration..." "WARNING"
        }
    }
}
catch {
    Write-Log "Critical error in main execution: ${_}" "ERROR"
    exit 1
}
finally {
    Stop-Monitoring
}