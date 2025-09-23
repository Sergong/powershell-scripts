#Requires -Modules NetApp.ONTAP

<#
.SYNOPSIS
    Debug script to test SVM name detection logic for CIFS session monitoring.

.DESCRIPTION
    This script connects to a NetApp ONTAP cluster and tests the SVM name detection
    logic used in the Monitor-CIFSSessions.ps1 script. It shows all SVM properties
    and tests which property name should be used for SVM identification.

.PARAMETER Cluster
    The NetApp ONTAP cluster hostname or IP address to test against.

.PARAMETER Credential
    PSCredential object for cluster authentication. If not provided, you will be prompted.

.PARAMETER TestSessionRetrieval
    Also test CIFS session retrieval for each detected SVM (without showing session details).

.EXAMPLE
    .\Debug-SVMNameDetection.ps1 -Cluster "cluster01.domain.com"

.EXAMPLE
    .\Debug-SVMNameDetection.ps1 -Cluster "10.1.1.100" -TestSessionRetrieval

.NOTES
    Author: PowerShell Scripts Repository
    Version: 1.0
    Purpose: Debug SVM name detection for Monitor-CIFSSessions.ps1
    Requires: NetApp.ONTAP PowerShell Module
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Cluster,
    
    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,
    
    [Parameter(Mandatory = $false)]
    [switch]$TestSessionRetrieval
)

# Function to write log messages with colors
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    
    switch ($Level) {
        "ERROR" { Write-Host $LogEntry -ForegroundColor Red }
        "WARNING" { Write-Host $LogEntry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $LogEntry -ForegroundColor Green }
        "DEBUG" { Write-Host $LogEntry -ForegroundColor Cyan }
        default { Write-Host $LogEntry -ForegroundColor White }
    }
}

# Function to test SVM name detection (same logic as main script)
function Test-SVMNameDetection {
    param($SVM)
    
    Write-Log "=== Testing SVM Name Detection ===" "DEBUG"
    
    # Try multiple property names for SVM name
    $SVMName = $null
    $PossibleNameProperties = @('Name', 'VserverName', 'Vserver', 'VServer', 'SvmName')
    
    Write-Log "Available properties on SVM object:" "DEBUG"
    $AllProperties = $SVM | Get-Member -MemberType Property | ForEach-Object { $_.Name }
    Write-Log "Properties: $($AllProperties -join ', ')" "DEBUG"
    
    Write-Log "Testing possible SVM name properties:" "DEBUG"
    foreach ($PropName in $PossibleNameProperties) {
        $PropValue = $null
        try {
            $PropValue = $SVM.$PropName
            if ($PropValue -and $PropValue -ne $null) {
                Write-Log "✅ Property '$PropName' exists with value: '$PropValue'" "SUCCESS"
                if (-not $SVMName) {
                    $SVMName = $PropValue
                    Write-Log "🎯 Selected '$PropName' as SVM name: '$SVMName'" "SUCCESS"
                }
            } else {
                Write-Log "❌ Property '$PropName' is null/empty" "WARNING"
            }
        } catch {
            Write-Log "❌ Property '$PropName' does not exist or error accessing: $_" "ERROR"
        }
    }
    
    if (-not $SVMName) {
        Write-Log "❌ ERROR: Could not determine SVM name from any property!" "ERROR"
        return $null
    }
    
    return $SVMName
}

# Function to show all SVM properties for debugging
function Show-SVMProperties {
    param($SVM, $SVMIndex)
    
    Write-Log "=== SVM #$SVMIndex - All Properties ===" "DEBUG"
    
    $SVM | Get-Member -MemberType Property | ForEach-Object {
        $PropName = $_.Name
        try {
            $PropValue = $SVM.$PropName
            if ($PropValue -ne $null) {
                # Handle different property types
                if ($PropValue -is [Array] -or $PropValue -is [System.Collections.IEnumerable] -and $PropValue -isnot [string]) {
                    # Handle arrays and collections
                    try {
                        $ArrayValues = @($PropValue) | ForEach-Object { $_.ToString() }
                        $DisplayValue = "[$($ArrayValues -join ', ')]"
                    } catch {
                        $DisplayValue = "[Array with $($PropValue.Count) items]"
                    }
                } else {
                    $DisplayValue = $PropValue.ToString()
                }
                
                # Truncate very long values
                if ($DisplayValue.Length -gt 100) {
                    $DisplayValue = $DisplayValue.Substring(0, 97) + "..."
                }
                
                Write-Log "  $PropName = $DisplayValue" "DEBUG"
            } else {
                Write-Log "  $PropName = <null>" "DEBUG"
            }
        } catch {
            Write-Log "  $PropName = <error accessing property: $_>" "ERROR"
        }
    }
}

# Main execution
try {
    Write-Host "NetApp SVM Name Detection Debug Tool" -ForegroundColor Cyan
    Write-Host "===================================" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Log "Target Cluster: $Cluster" "INFO"
    Write-Log "Test Session Retrieval: $TestSessionRetrieval" "INFO"
    Write-Host ""
    
    # Get credentials if not provided
    if (-not $Credential) {
        Write-Host "Please provide credentials for NetApp cluster $Cluster" -ForegroundColor Yellow
        $Credential = Get-Credential -Message "Enter credentials for NetApp cluster $Cluster"
        if (-not $Credential) {
            Write-Log "No credentials provided. Exiting." "ERROR"
            exit 1
        }
    }
    
    # Connect to NetApp cluster
    Write-Log "Connecting to NetApp cluster: $Cluster" "INFO"
    Connect-NcController -Name $Cluster -Credential $Credential -ErrorAction Stop | Out-Null
    Write-Log "Successfully connected to cluster $Cluster" "SUCCESS"
    
    # Verify cluster connectivity
    $ClusterInfo = Get-NcCluster
    Write-Log "Cluster Name: $($ClusterInfo.ClusterName)" "INFO"
    Write-Log "ONTAP Version: $($ClusterInfo.ClusterVersion)" "INFO"
    Write-Host ""
    
    # Get all data SVMs (filter out admin, system, and node SVMs)
    Write-Log "Retrieving all SVMs from cluster..." "INFO"
    $AllSVMs = Get-NcVserver
    
    if (-not $AllSVMs) {
        Write-Log "No SVMs found on cluster $Cluster" "WARNING"
        exit 1
    }
    
    Write-Log "Found $(($AllSVMs | Measure-Object).Count) total SVMs, filtering for data SVMs..." "INFO"
    
    # Filter for data SVMs only
    $DataSVMs = $AllSVMs | Where-Object {
        try {
            $_.VserverType -eq "data"
        } catch {
            # Fallback: if VserverType property doesn't exist, include it
            Write-Log "Warning: Could not check VserverType for SVM, including in analysis" "WARNING"
            $true
        }
    }
    
    if (-not $DataSVMs) {
        Write-Log "No data SVMs found on cluster $Cluster" "WARNING"
        Write-Log "Available SVM types: $(($AllSVMs | ForEach-Object { try { $_.VserverType } catch { 'Unknown' } } | Sort-Object | Get-Unique) -join ', ')" "INFO"
        exit 1
    }
    
    $SVMCount = ($DataSVMs | Measure-Object).Count
    Write-Log "Found $SVMCount data SVM(s)" "SUCCESS"
    
    # Show SVM type breakdown for reference
    $SVMTypeBreakdown = $AllSVMs | Group-Object { try { $_.VserverType } catch { 'Unknown' } } | ForEach-Object { "$($_.Name): $($_.Count)" }
    Write-Log "SVM type breakdown: $($SVMTypeBreakdown -join ', ')" "INFO"
    Write-Host ""
    
    # Test each SVM
    $SVMIndex = 0
    $SuccessfulSVMs = @()
    $FailedSVMs = @()
    
    foreach ($SVM in $DataSVMs) {
        $SVMIndex++
        Write-Log "Processing SVM #$SVMIndex of $SVMCount" "INFO"
        Write-Host ""
        
        # Show all properties for debugging
        Show-SVMProperties -SVM $SVM -SVMIndex $SVMIndex
        Write-Host ""
        
        # Test name detection
        $DetectedName = Test-SVMNameDetection -SVM $SVM
        
        if ($DetectedName) {
            # Properly handle AllowedProtocols array
            $ProtocolsDisplay = 'Unknown'
            try {
                if ($SVM.AllowedProtocols) {
                    if ($SVM.AllowedProtocols -is [Array]) {
                        $ProtocolsDisplay = $SVM.AllowedProtocols -join ','
                    } else {
                        $ProtocolsDisplay = $SVM.AllowedProtocols.ToString()
                    }
                }
            } catch {
                $ProtocolsDisplay = 'Error reading protocols'
            }
            
            $SuccessfulSVMs += [PSCustomObject]@{
                Index = $SVMIndex
                DetectedName = $DetectedName
                State = $SVM.State
                AllowedProtocols = $ProtocolsDisplay
            }
            
            # Test CIFS session retrieval if requested
            if ($TestSessionRetrieval) {
                Write-Log "Testing CIFS session retrieval for SVM: $DetectedName" "INFO"
                try {
                    $Sessions = Get-NcCifsSession -VserverContext $DetectedName -ErrorAction SilentlyContinue
                    if ($Sessions) {
                        $SessionCount = ($Sessions | Measure-Object).Count
                        Write-Log "✅ Successfully retrieved $SessionCount CIFS session(s)" "SUCCESS"
                        
                        # Show properties of first session for debugging
                        if ($Sessions.Count -gt 0) {
                            Write-Log "=== CIFS SESSION PROPERTIES DEBUG ===" "DEBUG"
                            $FirstSession = $Sessions[0]
                            $SessionProperties = @()
                            $FirstSession | Get-Member -MemberType Property | ForEach-Object {
                                $PropName = $_.Name
                                try {
                                    $PropValue = $FirstSession.$PropName
                                    if ($PropValue -ne $null) {
                                        if ($PropValue -is [Array] -and $PropValue.Count -gt 0) {
                                            $DisplayValue = "[$($PropValue -join ', ')]"
                                        } else {
                                            $DisplayValue = $PropValue.ToString()
                                        }
                                        if ($DisplayValue.Length -lt 100) {
                                            $SessionProperties += "$PropName=$DisplayValue"
                                        }
                                    } else {
                                        $SessionProperties += "$PropName=<null>"
                                    }
                                } catch {
                                    $SessionProperties += "$PropName=<error>"
                                }
                            }
                            Write-Log "First session properties: $($SessionProperties -join '; ')" "DEBUG"
                            Write-Log "Note: NetbiosName contains: '$($FirstSession.NetbiosName)'" "DEBUG"
                        }
                    } else {
                        Write-Log "✅ CIFS session retrieval successful (0 sessions found)" "SUCCESS"
                    }
                } catch {
                    Write-Log "❌ Error retrieving CIFS sessions: $_" "ERROR"
                }
            }
        } else {
            $FailedSVMs += [PSCustomObject]@{
                Index = $SVMIndex
                Error = "Could not detect SVM name"
            }
        }
        
        Write-Host ("-" * 80)
        Write-Host ""
    }
    
    # Summary
    Write-Log "=== SUMMARY ===" "SUCCESS"
    Write-Log "Total Data SVMs: $SVMCount" "INFO"
    Write-Log "Successfully detected: $(($SuccessfulSVMs | Measure-Object).Count)" "SUCCESS"
    
    # Only show failed count if there are actual failures
    $FailedCount = ($FailedSVMs | Measure-Object).Count
    if ($FailedCount -gt 0) {
        Write-Log "Failed to detect: $FailedCount" "ERROR"
    }
    
    Write-Host ""
    
    if ($SuccessfulSVMs) {
        Write-Log "Successfully Detected SVMs:" "SUCCESS"
        foreach ($SVM in $SuccessfulSVMs) {
            Write-Log "  SVM #$($SVM.Index): '$($SVM.DetectedName)' (State: $($SVM.State), Protocols: $($SVM.AllowedProtocols))" "SUCCESS"
        }
    }
    
    # Only show failed SVMs section if there are actual failures
    if ($FailedSVMs -and $FailedCount -gt 0) {
        Write-Host ""
        Write-Log "Failed SVMs:" "ERROR"
        foreach ($SVM in $FailedSVMs) {
            Write-Log "  SVM #$($SVM.Index): $($SVM.Error)" "ERROR"
        }
    }
    
    # CIFS-specific analysis
    Write-Host ""
    Write-Log "=== CIFS-ENABLED SVMs ANALYSIS ===" "INFO"
    $CIFSSVMs = $SuccessfulSVMs | Where-Object { 
        $_.AllowedProtocols -match 'cifs' -and $_.State -eq 'running' 
    }
    if ($CIFSSVMs) {
        Write-Log "CIFS-enabled running SVMs found: $(($CIFSSVMs | Measure-Object).Count)" "SUCCESS"
        foreach ($SVM in $CIFSSVMs) {
            Write-Log "  CIFS SVM: '$($SVM.DetectedName)'" "SUCCESS"
        }
        Write-Log "✅ Monitor-CIFSSessions.ps1 should work correctly with these SVMs" "SUCCESS"
    } else {
        Write-Log "❌ No CIFS-enabled running SVMs found" "WARNING"
        Write-Log "The main monitoring script may not find any SVMs to monitor" "WARNING"
    }
    
} catch {
    Write-Log "Critical error: $_" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
} finally {
    # Disconnect from cluster
    try {
        if (Get-Command "Disconnect-NcController" -ErrorAction SilentlyContinue) {
            Disconnect-NcController -ErrorAction SilentlyContinue
            Write-Log "Disconnected from NetApp cluster" "SUCCESS"
        } else {
            Write-Log "NetApp cluster connection will close automatically" "INFO"
        }
    } catch {
        Write-Log "Warning: Could not properly disconnect: $_" "WARNING"
    }
}

Write-Host ""
Write-Log "Debug script completed!" "SUCCESS"