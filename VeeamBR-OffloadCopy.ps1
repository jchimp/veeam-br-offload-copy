<#
.SYNOPSIS
    Copies Veeam B&R backup jobs repos to primary and secondary destinations using ROBOCOPY.
    
.DESCRIPTION
    Performs an offload copy of a Veeam B&R backup job from its local repository to network shares
    and rotated offsite drives (USB). Supports standard backup jobs, VMware backups, and NAS share jobs.
    Includes ROBOCOPY validation, path verification, comprehensive logging, and HTML email reporting.
    
    Global configuration (email, logging paths, SMTP settings) is loaded from VeeamBR-OffloadCopy.json.
    Each backup job should have its own batch file that calls this script with job-specific parameters.

.PARAMETER BackupJobName
    Name of the Veeam B&R backup job to copy. Required.

.PARAMETER PrimaryDestination
    Path to the primary destination for the backup copy. Can be UNC path or local path. Required.

.PARAMETER AltDestination1
    Path to the first alternate (secondary) destination. Checked before AltDestination2.

.PARAMETER AltDestination2
    Path to the second alternate (secondary) destination.

.PARAMETER DryRun
    When specified, simulates the entire copy process without executing ROBOCOPY or modifying files.
    Useful for testing and validation.

.PARAMETER ConfigFile
    Path to the JSON configuration file containing global settings (email, logging, SMTP server).
    Defaults to VeeamBR-OffloadCopy.json in the same directory as this script.
    This parameter is typically not needed unless using a non-standard config file location.

.EXAMPLE
    .\VeeamBR-OffloadCopy.ps1 -BackupJobName "Daily VM Backup" -PrimaryDestination "\\NAS\Backups"

.EXAMPLE
    .\VeeamBR-OffloadCopy.ps1 -BackupJobName "Daily VM Backup" -PrimaryDestination "D:\Backups" -AltDestination1 "E:\OffsiteUSB" -DryRun

.EXAMPLE
    .\VeeamBR-OffloadCopy.ps1 -BackupJobName "Daily Servers" -PrimaryDestination "\\SHBACKUPNAS01\VeeamBackups" -AltDestination1 "E:\VeeamBackups" -AltDestination2 "F:\VeeamBackups"

.EXAMPLE
    # From batch file scheduled in Veeam Job post-activity
    powershell -ExecutionPolicy Bypass "C:\Scripts\VeeamBR-OffloadCopy.ps1 -BackupJobName 'Daily Servers - Part 1' -PrimaryDestination '\\SHBACKUPNAS01\VeeamBackups' -AltDestination1 'E:\VeeamBackups' -AltDestination2 'F:\VeeamBackups'"

.NOTES
    Author: JPC <jeremy@championops.com>
    GitHub: https://github.com/jchimp/veeam-br-offsite-copy

    CHANGES:
    2022-11-15 - Created
    2022-12-02 - Updated to handle VMware Backup and NAS Share jobs
    2023-01-16 - Added Primary and Secondary copy location parameters
    2026-05-29 - Production hardening: error handling, ROBOCOPY validation, path validation, improved logging
    2026-05-29 - Modernized: HTML email reports, improved logging format, PowerShell help block
    2026-05-29 - Externalized global config to JSON file (VeeamBR-OffloadCopy.json)

#>

Param (
    [string]$BackupJobName = $(throw "-BackupJobName is required"),
    [string]$PrimaryDestination = $(throw "-PrimaryDestination is required"),
    [string]$AltDestination1, 
    [string]$AltDestination2, 
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'VeeamBR-OffloadCopy.json'),
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"
$VerbosePreference = "SilentlyContinue"

#######################################
# Settings
#######################################
$SecondaryDestination = ""
$MailTo = ""
$MailFrom = ""
$SmtpServer = ""
$configBackupFolder = ""
$transcriptPath = ""

$copyDestPrimary = ""
$copyDestSecondary = ""
$copySource = ""

$copyFlags    = @("/e", "/copy:dat", "/dcopy:dat", "/w:30", "/r:3", "/fft", "/z", "/np", "/mt:16") 
$copyOptions  = @("/mir", "/xf", "thumbs.db", "desktop.ini")

$transcriptName = "ROBOCOPY-VBROffload_NAME_Log.txt"

# Counters for tracking operations
$RoboCopyErrors = @()
$warningMessages = @()
$copyOperations = @()
$roboCopyStats = @{}

# Script mode tracking
$script:DryRunMode = $DryRun.IsPresent
$script:ActiveLogFile = $null

# Initialize timing
$startDateTime = $null
$endDateTime = $null

#######################################
# Functions
#######################################

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")

    $tag   = if ($script:DryRunMode) { "[DRY-RUN] " } else { "" }
    $logLevel = if ($Level -eq "DRYRUN") { "INFO" } else { $Level }
    $entry = "[$logLevel] ${tag}$Message"

    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        "WARN"    { Write-Host $entry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green }
        "DRYRUN"  { Write-Host $entry -ForegroundColor Cyan }
        default   { Write-Host $entry }
    }
}

function Test-RoboCopySuccess {
    param([int]$ExitCode, [string]$Operation)
    # ROBOCOPY exit codes: 0-3 = success, 4+ = errors
    # 0 = No files copied
    # 1 = All files copied successfully
    # 2 = Some extra files in destination
    # 3 = Some files copied, some extra in destination
    # 4+ = Some files failed to copy (exit code 4-7 have varying degrees)
    
    if ($ExitCode -ge 4) {
        $errorMsg = "ROBOCOPY $Operation failed with exit code $ExitCode (errors occurred during copy)"
        Write-Log $errorMsg "ERROR"
        $script:RoboCopyErrors += $errorMsg
        return $false
    }
    return $true
}

function Get-VolumeInfo {
    param([string]$Path)
    try {
        if ($Path -like "\\*") { return "" }        # UNC path, no drive letter, cannot get volume label
        $driveLetter = (Split-Path -Qualifier $Path).TrimEnd(":")
        $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
        return $volume.FileSystemLabel
    }
    catch {
        Write-Log "Could not get volume label for $Path : $_" "WARN"
        $script:warningMessages += "Could not retrieve volume label for $Path"
        return ""
    }
}

function Rotate-TranscriptLogs {
    param([string]$FilePath)
    try {
        # Rotate the last 3 logs
        If (Test-Path(($FilePath + ".3"))) { Remove-Item ($FilePath + ".3") -Force -ErrorAction Stop }
        If (Test-Path(($FilePath + ".2"))) { Move-Item -Force ($FilePath + ".2") -Destination ($FilePath + ".3") -ErrorAction Stop }
        If (Test-Path(($FilePath + ".1"))) { Move-Item -Force ($FilePath + ".1") -Destination ($FilePath + ".2") -ErrorAction Stop }
        If (Test-Path($FilePath)) { Move-Item -Force $FilePath -Destination ($FilePath + ".1") -ErrorAction Stop }
        Sleep 0.1
    }
    catch {
        Write-Log "Could not rotate transcript logs: $_" "WARN"
        $script:warningMessages += "Transcript log rotation failed: $_"
    }
}

function Test-PathAccessibility {
    param([string]$Path, [string]$PathName)
    If (-not (Test-Path -Path $Path)) {
        Write-Log "$PathName path is not accessible: $Path" "ERROR"
        return $false
    }
    return $true
}

function Parse-RoboCopyStats {
    param([string]$LogContent)
    
    # Parse ROBOCOPY log output for statistics
    # Looking for lines like:
    # New Files        : 1234
    # Bytes Copied     : 1,234,567,890
    
    $stats = @{
        FilesCount = 0
        BytesCopied = 0
        Speed = ""
    }
    
    try {
        # Extract file count
        if ($LogContent -match "New Files\s+:\s+([\d,]+)") {
            $stats.FilesCount = [int]($matches[1] -replace ",", "")
        }
        
        # Extract bytes copied
        if ($LogContent -match "Bytes Copied\s+:\s+([\d,]+)") {
            $stats.BytesCopied = [long]($matches[1] -replace ",", "")
        }
        
        # Extract speed (e.g., "1.5 m/s")
        if ($LogContent -match "Speed\s+:\s+([\d.,]+\s+[a-z/]+)") {
            $stats.Speed = $matches[1]
        }
    }
    catch {
        Write-Log "Could not parse ROBOCOPY statistics: $_" "WARN"
    }
    
    return $stats
}

function Format-BytesToMB {
    param([long]$Bytes)
    if ($Bytes -eq 0) { return "0 MB" }
    return "{0:N2} MB" -f ($Bytes / 1MB)
}

function Test-JsonConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "Configuration file not found: $Path"
        return $false
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to read configuration file: $_"
        return $false
    }
    
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Error "Configuration file is empty: $Path"
        return $false
    }

    try {
        $null = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Error "Configuration file contains invalid JSON: $_"
        return $false
    }

    return $true
}


#######################################
# ENTRY POINT
#######################################

try {
    # Validate and load configuration file
    if (-not (Test-JsonConfig -Path $ConfigFile)) { 
        Write-Error "Failed to validate configuration file. Exiting."
        exit 1 
    }

    $config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json

    # Load config values
    $configBackupFolder = $config.VeeamConfigBackupFolder
    $transcriptPath = $config.LogPath
    $MailTo = $config.Smtp.To
    $MailFrom = $config.Smtp.From
    $SmtpServer = $config.Smtp.Server

    # Validate config values are not empty
    if ([string]::IsNullOrWhiteSpace($configBackupFolder)) { 
        throw "VeeamConfigBackupFolder not set in config file: $ConfigFile"
    }
    if ([string]::IsNullOrWhiteSpace($transcriptPath)) { 
        throw "LogPath not set in config file: $ConfigFile"
    }
    if ([string]::IsNullOrWhiteSpace($MailTo)) { 
        throw "Smtp.To not set in config file: $ConfigFile"
    }
    if ([string]::IsNullOrWhiteSpace($MailFrom)) { 
        throw "Smtp.From not set in config file: $ConfigFile"
    }
    if ([string]::IsNullOrWhiteSpace($SmtpServer)) { 
        throw "Smtp.Server not set in config file: $ConfigFile"
    }

    # Parameter check and normalization
    If ($BackupJobName.Length -le 0) { throw "Backup job name not specified." }
    If ($PrimaryDestination.Length -le 0) { throw "Primary destination path not specified." }
    
    # Create/rotate transcript log file
    $transcriptName = ("VBR-OffloadCopy_" + $BackupJobName.Replace(" ", "") + "_Log.txt")
    If ($transcriptPath.Length -gt 0 -and (Test-Path($transcriptPath))) { 
        $transcriptFilename = Join-Path -Path $transcriptPath -ChildPath $transcriptName
        $script:ActiveLogFile = $transcriptFilename
    }
    Else { 
        $transcriptFilename = Join-Path -Path $env:TEMP -ChildPath $transcriptName
        $script:ActiveLogFile = $transcriptFilename
    }

    # Rotate the last 3 logs
    Rotate-TranscriptLogs -FilePath $transcriptFilename

    # Start 
    $startDateTime = (Get-Date)
    Start-Transcript -Force -Path $transcriptFilename

    # Start with success status
    $subjectStatus = "Success"

    # Computer/server info
    $Servername = $env:COMPUTERNAME
    $ServernameFQDN = (($Servername).ToLower() + "." + ($env:USERDNSDOMAIN).ToLower())

    # Display header
    if ($script:DryRunMode) {
        Write-Host ""
        Write-Host "  +============================================+" -ForegroundColor Cyan
        Write-Host "  |      DRY-RUN MODE - NO CHANGES MADE        |" -ForegroundColor Cyan
        Write-Host "  |    No ROBOCOPY execution or file changes    |" -ForegroundColor Cyan
        Write-Host "  +============================================+" -ForegroundColor Cyan
        Write-Host ""
    }

    # Figure out which AltDestination to use for the SecondaryDestination value
    If (Test-Path -Path $AltDestination1) { 
        $SecondaryDestination = $AltDestination1 
    }
    ElseIf (Test-Path -Path $AltDestination2) { 
        $SecondaryDestination = $AltDestination2 
    }
    Else {
        $SecondaryDestination = ""
        Write-Log "No secondary destination paths are accessible." "WARN"
        $script:warningMessages += "No secondary destination available"
    }

    # Header / Summary
    Write-Log "========================================================="
    Write-Log "Veeam B&R - Offload Copy"
    Write-Log "========================================================="
    Write-Log ("Server:          " + $Servername + " (" + $ServernameFQDN + ")")
    Write-Log ("Backup Job:      " + $BackupJobName)
    Write-Log ("Primary Dest:    " + $PrimaryDestination.ToString())
    Write-Log ("Secondary Dest:  " + $SecondaryDestination.ToString())
    Write-Log "========================================================="

    Write-Log "Getting configuration backup job..."

    # Get Veeam Config job - we want to make a copy of it with this "offload" copy
    $configJob = Get-VBRConfigurationBackupJob -ErrorAction SilentlyContinue
    $configRepo = $null
    $configBackupSource = ""
    If ($configJob) {
        $configRepo = $configJob.Repository
        If ($configRepo)  {
            $configBackupSource = Join-Path -Path $configRepo.FriendlyPath -ChildPath $configBackupFolder

            # Make sure it exists
            If ((Test-Path($configBackupSource))) {
                Write-Log ("Configuration Backup:     " + $configBackupSource)
            }
            Else {
                $configBackupSource = ""
                Write-Log "Could not verify existence of configuration backup folder...Skipping." "WARN"
                $script:warningMessages += "Configuration backup folder not found or not accessible"
            }
        }
        Else {
            $configBackupSource = ""
            Write-Log "Could not get configuration backup repository...Skipping." "WARN"
            $script:warningMessages += "Configuration backup repository unavailable"
        }
    }
    Else {
        $configBackupSource = ""
        Write-Log "Could not get configuration backup job...Skipping." "WARN"
        $script:warningMessages += "Configuration backup job not found"
    }

    Write-Log ""
    Write-Log "Getting Veeam B&R Job..."

    # Get the Job and Repo objects
    $job = Get-VBRJob -Name $BackupJobName -ErrorAction SilentlyContinue
    If (-not $job) {
        throw "Could not find backup job: $BackupJobName"
    }

    $lastResult = $job.GetLastResult()
    If ($lastResult -eq "Failed") {
        throw "Last backup job result was 'Failed'. Not proceeding with offload copy."
    }

    Write-Log ("Job Name:          " + $job.Name)
    Write-Log ("Last Run:          " + $job.LatestRunLocal.ToString("yyyy-MM-dd hh:mm tt"))
    Write-Log ("Last Result:       " + $lastResult.ToString())

    Write-Log ""
    Write-Log "Getting backup repository and local extent..."

    # Get Job Repo and the path to the repo or the path to the extents of the repo
    $jobRepo = $job.GetBackupTargetRepository()
    If (-not $jobRepo) {
        throw "Could not get backup target repository for job: $BackupJobName"
    }

    $repoPath = $null
    If ($jobRepo.Type -eq "WinLocal") {
        # Local Disk Repo
        Write-Log ("Repository Name:   " + $jobRepo.Name)
        Write-Log ("Repository Path:   " + $jobRepo.FriendlyPath)
        $repoPath = $jobRepo.FriendlyPath
    }
    ElseIf ($jobRepo.Type -eq "ExtendableRepository") {
        # SOBR Repo
        $repoExtents = $jobRepo.GetExtents()
        If ($repoExtents.Length -eq 1) {
            $repoExt = $repoExtents[0]
            If ($repoExt.Type -eq "WinLocal") {
                Write-Log ("Repository Name:   " + $jobRepo.Name)
                Write-Log ("Extent Name:       " + $repoExt.Name)
                Write-Log ("Extent Path:       " + $repoExt.FriendlyPath)
                $repoPath = $repoExt.FriendlyPath
            }
            Else {
                throw "First extent is not a 'WinLocal' extent. Extent type '$($repoExt.Type)' not supported."
            }
        }
        Else {
            If($repoExtents.Length -gt 1) { 
                throw "More than 1 repo extent exists ($($repoExtents.Length)). Not supported." 
            }
            Else { 
                throw "Could not get extents for the repository: $($jobRepo.Name)" 
            }
        }
    }
    Else {
        throw "Repository type '$($jobRepo.Type)' is not supported. Only WinLocal and ExtendableRepository types are supported."
    }

    Write-Log ""
    Write-Log "Getting backup chain from the job..."    

    # Get backup dir from the backup so we can append it to the repo path for the full path to the backup files
    $backupDir = $null
    If ($job.IsBackupJob) {
        $backup = Get-VBRBackup -Name $BackupJobName -ErrorAction SilentlyContinue
        If ($backup) {
            $backupDir = $backup.DirPath.ToString()
            Write-Log ("Backup Dir:        " + $backupDir)
        }
        Else {
            throw "Could not get backup or backup chain for job: $BackupJobName"
        }
    } ElseIf ($job.IsNasBackup) {
        $backupDir = $job.TargetFile
        Write-Log ("Backup Dir:        " + $backupDir)
    }
    Else {
        throw "Unsupported backup job type. Job must be a standard backup or NAS backup job."
    }

    # Validate we have everything before proceeding
    If (-not $job -or -not $jobRepo -or -not $repoPath -or -not $backupDir) {
        throw "Missing required information: Job=$($null -ne $job) Repo=$($null -ne $jobRepo) RepoPath=$($null -ne $repoPath) BackupDir=$($null -ne $backupDir)"
    }

    # Validate Primary destination is accessible
    If (-not (Test-PathAccessibility -Path $PrimaryDestination -PathName "Primary destination")) {
        throw "Primary destination is not accessible: $PrimaryDestination"
    }

    # Copy to network and offsite storage
    # Build Source path, and get destination path for ROBOCOPY
    $copySource = Join-Path -Path $repoPath -ChildPath $backupDir
    $destPath = $copySource.Substring(3)	# Remove drive letter (e.g., "C:\")

    # Add listing flag if we are in dry run mode
    If ($script:DryRunMode) { $copyFlags += "/l" }

    # Remove listing files if it's a File Share (NAS) backup job. The list will be too big for email.
    If ($job.IsNasBackup) { $copyFlags += "/nfl" }

    Write-Log ""
    Write-Log "====================================================="
    Write-Log "Copying backup to PRIMARY location..."
    Write-Log "====================================================="
    Write-Log ""

    #############################
    # Copy to Primary path/destination
    #############################
    $copyDestPrimary = Join-Path -Path $PrimaryDestination -ChildPath $destPath
    $copyDestPrimaryConfig = Join-Path -Path $PrimaryDestination -ChildPath $configBackupSource.Substring(3)

    Write-Log ("Source Path:      " + $copySource)
    Write-Log ("Destination Path: " + $copyDestPrimary)

    $PrimaryDestVolName = Get-VolumeInfo -Path $PrimaryDestination
    If ($PrimaryDestVolName.Length -gt 0) { Write-Log ("Destination Vol:  " + $PrimaryDestVolName) }

    If (Test-Path($PrimaryDestination))
    {
        if ($script:DryRunMode) {
            Write-Log "Would execute: ROBOCOPY `"$copySource`" `"$copyDestPrimary`" (with flags)" "DRYRUN"
        }
        else {
            $roboCopyOutput = ROBOCOPY "$copySource" "$copyDestPrimary" $copyFlags $copyOptions 2>&1 | Out-String
            $roboCopyStats["PRIMARY"] = Parse-RoboCopyStats -LogContent $roboCopyOutput
        }
        $primaryExitCode = $LASTEXITCODE

        Write-Log "ROBOCOPY exit code: $primaryExitCode"
        $primaryStatus = if (Test-RoboCopySuccess -ExitCode $primaryExitCode -Operation "PRIMARY") { "SUCCESS" } else { "FAILED" }
        
        $copyOperations += @{
            Destination = "PRIMARY"
            Source = $copySource
            Target = $copyDestPrimary
            ExitCode = $primaryExitCode
            Status = $primaryStatus
        }
        
        if ($primaryStatus -eq "FAILED") { $subjectStatus = "FAILED" }
        
        If($configBackupSource.Length -gt 0) {
            Write-Log ""
            Write-Log "Copying configuration backup to primary location..."

            if ($script:DryRunMode) {
                Write-Log "Would execute: ROBOCOPY `"$configBackupSource`" `"$copyDestPrimaryConfig`" (with flags)" "DRYRUN"
            }
            else {
                ROBOCOPY "$configBackupSource" "$copyDestPrimaryConfig" $copyFlags $copyOptions
            }
            $configPrimaryExitCode = $LASTEXITCODE

            Write-Log "ROBOCOPY exit code: $configPrimaryExitCode"
            $configPrimaryStatus = if (Test-RoboCopySuccess -ExitCode $configPrimaryExitCode -Operation "PRIMARY CONFIG") { "SUCCESS" } else { "FAILED" }
            
            if ($configPrimaryStatus -eq "FAILED") {
                $subjectStatus = "FAILED"
            }
        }
    }
    Else {
        $subjectStatus = "FAILED"
        throw "Primary destination path is not reachable: $PrimaryDestination"
    }

    #############################
    # Copy to Secondary path/destination
    #############################   
    If($SecondaryDestination.Length -gt 0) {
        Write-Log ""
        Write-Log ""
        Write-Log "====================================================="
        Write-Log "Copying backup to SECONDARY location..."
        Write-Log "====================================================="
        Write-Log ""

        $copyDestSecondary = Join-Path -Path $SecondaryDestination -ChildPath $destPath
        $copyDestSecondaryConfig = Join-Path -Path $SecondaryDestination -ChildPath $configBackupSource.Substring(3)

        Write-Log ("Source Path:      " + $copySource)
        Write-Log ("Destination Path: " + $copyDestSecondary)

        $SecondaryDestVolName = Get-VolumeInfo -Path $SecondaryDestination
        If ($SecondaryDestVolName.Length -gt 0) { Write-Log ("Destination Vol:  " + $SecondaryDestVolName) }

        If (Test-Path($SecondaryDestination)) {

            if ($script:DryRunMode) {
                Write-Log "Would execute: ROBOCOPY `"$copySource`" `"$copyDestSecondary`" (with flags)" "DRYRUN"
            }
            else {
                $roboCopyOutput = ROBOCOPY "$copySource" "$copyDestSecondary" $copyFlags $copyOptions 2>&1 | Out-String
                $roboCopyStats["SECONDARY"] = Parse-RoboCopyStats -LogContent $roboCopyOutput
            }
            $secondaryExitCode = $LASTEXITCODE
            
            Write-Log "ROBOCOPY exit code: $secondaryExitCode"
            $secondaryStatus = if (Test-RoboCopySuccess -ExitCode $secondaryExitCode -Operation "SECONDARY") { "SUCCESS" } else { "FAILED" }
            
            $copyOperations += @{
                Destination = "SECONDARY"
                Source = $copySource
                Target = $copyDestSecondary
                ExitCode = $secondaryExitCode
                Status = $secondaryStatus
            }
            
            if ($secondaryStatus -eq "FAILED") { $subjectStatus = "FAILED" }

            If ($configBackupSource.Length -gt 0) {
                Write-Log ""
                Write-Log "Copying configuration backup to secondary location..."
                
                if ($script:DryRunMode) {
                    Write-Log "Would execute: ROBOCOPY `"$configBackupSource`" `"$copyDestSecondaryConfig`" (with flags)" "DRYRUN"
                }
                else {
                    ROBOCOPY "$configBackupSource" "$copyDestSecondaryConfig" $copyFlags $copyOptions
                }
                $configSecondaryExitCode = $LASTEXITCODE
                
                Write-Log "ROBOCOPY exit code: $configSecondaryExitCode"
                $configSecondaryStatus = if (Test-RoboCopySuccess -ExitCode $configSecondaryExitCode -Operation "SECONDARY CONFIG") { "SUCCESS" } else { "FAILED" }
                
                if ($configSecondaryStatus -eq "FAILED") {
                    $subjectStatus = "FAILED"
                }
            }
        }
        Else {
            $subjectStatus = "FAILED"
            Write-Log "Secondary destination path is not reachable: $SecondaryDestination" "ERROR"
            $script:RoboCopyErrors += "Secondary destination not accessible: $SecondaryDestination"
        }
    }
    Else {
        Write-Log ""
        Write-Log "No secondary destination available. Skipping secondary copy."
    }

    Write-Log ""
    Write-Log "Offload copy complete."
}
catch {
    Write-Log ""
    Write-Log "Script execution failed!" "ERROR"
    Write-Log ("Error Message: " + $_.Exception.Message) "ERROR"
    Write-Log ("Error Details: " + $_.Exception) "ERROR"
    $subjectStatus = "FAILED"
}

# Get the current time and calculate the duration
$endDateTime = (Get-Date)
$duration = ($endDateTime - $startDateTime)

# Summary
Write-Log ""
Write-Log "========================================================="
Write-Log "Veeam B&R - Offload Copy - SUMMARY"
Write-Log "========================================================="
Write-Log ("Status:           " + $subjectStatus)
Write-Log ""
Write-Log ("Backup Job:       " + $BackupJobName)
Write-Log ("Source Path:      " + $copySource)
Write-Log ""
If ($PrimaryDestVolName.Length -gt 0) { Write-Log ("Primary Vol:      " + $PrimaryDestVolName) }
Write-Log ("Primary Dest:     " + $PrimaryDestination)
Write-Log ""
If ($SecondaryDestVolName.Length -gt 0) { Write-Log ("Secondary Vol:    " + $SecondaryDestVolName) }
Write-Log ("Secondary Dest:   " + $SecondaryDestination)
Write-Log ""
Write-Log ("Start Date/Time:  " + $startDateTime.ToString("yyyy-MM-dd HH:mm:ss"))
Write-Log ("End Date/Time:    " + $endDateTime.ToString("yyyy-MM-dd HH:mm:ss"))
Write-Log ("Duration:         " + ([string]::format("{0:00}:{1:00}:{2:00}", $duration.Hours, $duration.Minutes, $duration.Seconds)))

If ($RoboCopyErrors.Count -gt 0) {
    Write-Log ""
    Write-Log "ROBOCOPY Errors:" "ERROR"
    ForEach ($errorMsg in $RoboCopyErrors) {
        Write-Log ("  - " + $errorMsg) "ERROR"
    }
}

If ($warningMessages.Count -gt 0) {
    Write-Log ""
    Write-Log "Warnings:" "WARN"
    ForEach ($warning in $warningMessages) {
        Write-Log ("  - " + $warning) "WARN"
    }
}

Write-Log "========================================================="
Write-Log ""

# End
Stop-Transcript

# Email results
try {
    $dryTag = if ($script:DryRunMode) { " [DRY-RUN]" } else { "" }
    $MailSubject = ("[$subjectStatus] VBR Offload - $BackupJobName ($Servername)" + $dryTag)

    # Build HTML email body
    $reportTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    $operationRows = ""
    foreach ($op in $copyOperations) {
        $statusColor = switch ($op.Status) {
            "SUCCESS" { "#2e7d32" }
            "FAILED"  { "#c62828" }
            default   { "#f57c00" }
        }
        $statusIcon = switch ($op.Status) {
            "SUCCESS" { "&#10003;" }
            "FAILED"  { "&#10007;" }
            default   { "&#9888;" }
        }

        $destEscaped = [System.Net.WebUtility]::HtmlEncode($op.Destination)

        # Get stats for this operation
        $opStats = $roboCopyStats[$op.Destination]
        $filesInfo = if ($opStats) { "$($opStats.FilesCount) files" } else { "N/A" }
        $bytesInfo = if ($opStats) { Format-BytesToMB -Bytes $opStats.BytesCopied } else { "N/A" }
        $speedInfo = if ($opStats -and $opStats.Speed) { $opStats.Speed } else { "N/A" }

        $operationRows += @"
        <tr>
            <td style="padding:8px;border:1px solid #ddd;">$destEscaped</td>
            <td style="padding:8px;border:1px solid #ddd;color:${statusColor};font-weight:bold;">$statusIcon $($op.Status)</td>
            <td style="padding:8px;border:1px solid #ddd;font-size:0.9em;">$filesInfo</td>
            <td style="padding:8px;border:1px solid #ddd;font-size:0.9em;">$bytesInfo</td>
            <td style="padding:8px;border:1px solid #ddd;font-size:0.9em;">$speedInfo</td>
        </tr>
"@
    }

    $configSummary = @"
    <table style="border-collapse:collapse;margin-bottom:16px;width:100%;border:none;">
        <tr style="border:none;">
            <td style="padding:4px 12px 4px 0;color:#555;font-weight:bold;width:180px;border:none;">Job Name:</td>
            <td style="padding:4px 0;border:none;">$([System.Net.WebUtility]::HtmlEncode($BackupJobName))</td>
        </tr>
        <tr style="border:none;">
            <td style="padding:4px 12px 4px 0;color:#555;font-weight:bold;width:180px;border:none;">Last Run:</td>
            <td style="padding:4px 0;border:none;">$($job.LatestRunLocal.ToString('yyyy-MM-dd HH:mm:ss'))</td>
        </tr>
        <tr style="border:none;">
            <td style="padding:4px 12px 4px 0;color:#555;font-weight:bold;width:180px;border:none;">Last Result:</td>
            <td style="padding:4px 0;border:none;">$lastResult</td>
        </tr>
        <tr style="border:none;">
            <td style="padding:4px 12px 4px 0;color:#555;font-weight:bold;width:180px;border:none;">Source Repository:</td>
            <td style="padding:4px 0;border:none;">$([System.Net.WebUtility]::HtmlEncode($repoPath))</td>
        </tr>
        <tr style="border:none;">
            <td style="padding:4px 12px 4px 0;color:#555;font-weight:bold;width:180px;border:none;">Primary Destination:</td>
            <td style="padding:4px 0;border:none;">$([System.Net.WebUtility]::HtmlEncode($PrimaryDestination))</td>
        </tr>
        <tr style="border:none;">
            <td style="padding:4px 12px 4px 0;color:#555;font-weight:bold;width:180px;border:none;">Secondary Destination:</td>
            <td style="padding:4px 0;border:none;">$(if ($SecondaryDestination.Length -gt 0) { [System.Net.WebUtility]::HtmlEncode($SecondaryDestination) } else { "N/A" })</td>
        </tr>
    </table>
"@

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <style>
        body { font-family:Segoe UI,Arial,sans-serif; margin:0; padding:12px; background:#fff; }
        .container { max-width:900px; background:#fff; padding:16px; border-radius:4px; box-shadow:0 1px 3px rgba(0,0,0,0.1); }
        h2 { margin:0 0 8px 0; font-size:1.4em; color:#333; }
        h3 { margin:12px 0 8px 0; font-size:1.1em; color:#333; border-bottom:2px solid #1565c0; padding-bottom:4px; }
        p { margin:0 0 4px 0; color:#666; font-size:0.95em; }
        table { border-collapse:collapse; width:100%; margin-bottom:12px; }
        th { background:#1565c0; color:#fff; padding:8px; text-align:left; font-weight:600; font-size:0.9em; }
        td { padding:6px 8px; border:1px solid #e0e0e0; font-size:0.9em; }
        .summary-table tr { border:none; }
        .summary-table td { border:none; padding:3px 0; font-size:0.9em; }
        .summary-table td:first-child { color:#555; font-weight:600; padding-right:12px; }
        .success { color:#2e7d32; }
        .failed { color:#c62828; }
        .warning { color:#e65100; }
        ul { margin:4px 0; padding-left:20px; }
        li { margin:2px 0; }
        .footer { color:#999; font-size:0.8em; margin-top:12px; text-align:center; border-top:1px solid #e0e0e0; padding-top:8px; }
    </style>
</head>
<body>
    <div class="container">
        <h2>Veeam B&R Offload Copy Report$dryTag</h2>
        <p>
            <strong>Server:</strong> $Servername &nbsp;|&nbsp;
            <strong>Time:</strong> $reportTime &nbsp;|&nbsp;
            <strong>Status:</strong> <span class="$(if ($subjectStatus -eq 'SUCCESS') { 'success' } else { 'failed' })"><strong>$subjectStatus</strong></span>
        </p>
        
        <h3>Job Details</h3>
        $configSummary

        <h3>Copy Operations</h3>
        <table>
            <tr>
                <th>Destination</th>
                <th>Status</th>
                <th>Files Copied</th>
                <th>Data Transferred</th>
                <th>Speed</th>
            </tr>
            $operationRows
        </table>

        <h3>Summary</h3>
        <table class="summary-table">
            <tr>
                <td style="padding:4px 12px 4px 0;color:#555;font-weight:bold;width:180px;">Start Time:</td>
                <td style="padding:4px 0;">$($startDateTime.ToString('yyyy-MM-dd HH:mm:ss'))</td>
            </tr>
            <tr>
                <td style="padding:4px 12px 4px 0;color:#555;font-weight:bold;width:180px;">End Time:</td>
                <td style="padding:4px 0;">$($endDateTime.ToString('yyyy-MM-dd HH:mm:ss'))</td>
            </tr>
            <tr>
                <td style="padding:4px 12px 4px 0;color:#555;font-weight:bold;width:180px;">Duration:</td>
                <td style="padding:4px 0;">$([string]::format("{0:00}:{1:00}:{2:00}", $duration.Hours, $duration.Minutes, $duration.Seconds))</td>
            </tr>
        </table>
"@

    if ($RoboCopyErrors.Count -gt 0) {
        $errorRows = ""
        foreach ($err in $RoboCopyErrors) {
            $errEscaped = [System.Net.WebUtility]::HtmlEncode($err)
            $errorRows += "<li>$errEscaped</li>"
        }
        $html += @"
        <h3 class="failed">⚠️ Errors</h3>
        <ul>$errorRows</ul>
"@
    }

    if ($warningMessages.Count -gt 0) {
        $warningRows = ""
        foreach ($warn in $warningMessages) {
            $warnEscaped = [System.Net.WebUtility]::HtmlEncode($warn)
            $warningRows += "<li>$warnEscaped</li>"
        }
        $html += @"
        <h3 class="warning">⚠️ Warnings</h3>
        <ul>$warningRows</ul>
"@
    }

    $html += @"
        <div class="footer">
            Generated by VeeamBR-OffsiteCopy.ps1 | GitHub: <a href="https://github.com/jchimp/veeam-br-offsitecopy" style="color:#999;">jchimp/veeam-br-offsite-copy</a>
        </div>
    </div>
</body>
</html>
"@

    if ($script:DryRunMode) {
        Write-Log "Would send email report:" "DRYRUN"
        Write-Log "  From:    $MailFrom" "DRYRUN"
        Write-Log "  To:      $MailTo" "DRYRUN"
        Write-Log "  Subject: $MailSubject" "DRYRUN"
        Write-Log "  Server:  $SmtpServer" "DRYRUN"
    }
    else {
        Send-MailMessage -From $MailFrom -To $MailTo -Subject $MailSubject -Body $html -BodyAsHtml -SmtpServer $SmtpServer -Attachments $transcriptFilename -ErrorAction Stop
        Write-Log "Email notification sent successfully." "SUCCESS"
    }
}
catch {
    Write-Log "Failed to send email notification: $_" "ERROR"
    Write-Log ("Email would have been sent to: " + $MailTo) "ERROR"
    Write-Log ("Subject: " + $MailSubject) "ERROR"
}