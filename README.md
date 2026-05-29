# Veeam Backup & Recovery - Offload Copy Script

A PowerShell script that automates offloading Veeam Backup & Replication jobs to network shares and rotated offsite storage drives (USB, external drives, etc.).

The secondary location is typically a rotated offsite drive (USB) or network share. 
That is why we have AltDestination exists, we use it to specify the two locations the USB drive might show up as.

## How It Works

1. **Validates** the specified backup job exists and completed successfully
2. **Retrieves** the backup repository path from Veeam
3. **Copies** the backup files to a primary destination, and secondary destination (if available) using RoboCopy
4. **Includes** Veeam configuration backups in the copy operations
5. **Logs** all operations and sends results via email

## Features

- Supports standard Veeam backup jobs and NAS backup jobs
- Handles both single repository and Scale-Out Backup Repository (SOBR) configurations
- Rotates between two alternate offsite storage drives automatically
- Logging with transcript rotation (keeps last 3 logs)
- Email notifications with results

## Installation

### Step 1: Configure Global Settings

Create a JSON configuration file named `VeeamBR-OffloadCopy.json` in the same directory as the PowerShell script with your environment settings:

```json
{
  "VeeamConfigBackupFolder": "VeeamConfigBackup",
  "LogPath": "C:\\Logs",
  "Smtp": {
    "Server": "smtp.company.com",
    "From": "backup@company.com",
    "To": "user@company.com"
  }
}
```

**Configuration Fields:**
- **VeeamConfigBackupFolder**: Folder name where Veeam stores configuration backups (subdirectory name only)
- **LogPath**: Full path where transcript logs will be stored (directory must exist or script will use temp folder)
- **Smtp.Server**: SMTP server hostname for sending email reports
- **Smtp.From**: Sender email address for reports
- **Smtp.To**: Recipient email address (single email or comma-separated list)

> **Note:** The JSON config file is loaded automatically on each script execution. All global settings (email, logging paths) are read from this file, so you only need to configure it once.

### Step 2: Install PowerShell Script

Copy `VeeamBR-OffloadCopy.ps1` to your scripts folder (e.g., `C:\Scripts\`)

### Step 3: Create Batch Files for Each Backup Job

Create a separate batch file for each Veeam backup job you want to offload. This allows you to schedule each job independently in Veeam's job settings.

**Example:** `VeeamBR-OffloadCopy_DailyServers.bat`

```batch
@ECHO OFF
powershell -ExecutionPolicy Bypass ".\VeeamBR-OffloadCopy.ps1 -BackupJobName 'Daily Servers' -PrimaryDestination '\\NAS01\VeeamBackups' -AltDestination1 'E:\VeeamBackups' -AltDestination2 'F:\VeeamBackups'"
```

Create similar batch files for each backup job:
- `VeeamBR-OffloadCopy_DailyDCs.bat`
- `VeeamBR-OffloadCopy_DailyVMs.bat`
- `VeeamBR-OffloadCopy_DailyExchange.bat`
- etc.

### Step 4: Schedule in Veeam

In Veeam Backup & Replication:

1. Open your backup job properties
2. Go to **Backup Job** → **Advanced** → **Scripts**
3. Set the batch file as a **Post-job activity script** (runs after backup completes)
4. Configure it to run as a service account with appropriate permissions

Alternatively, schedule each batch file as a Windows Task Scheduler task to run after the corresponding backup job completes.

## Parameters

### Required Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-BackupJobName` | String | Name of the Veeam backup job to offload (must match exactly) |
| `-PrimaryDestination` | String | Path to primary backup destination (network share or local path) |

### Optional Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-AltDestination1` | String | (empty) | Path to first alternate offsite storage location (USB/external drive) |
| `-AltDestination2` | String | (empty) | Path to second alternate offsite storage location (USB/external drive) |
| `-DryRun` | Switch | `$false` | Performs a dry-run without actually copying files or modifying anything |
| `-ConfigFile` | String | `VeeamBR-OffloadCopy.json` | Path to JSON configuration file (auto-detected in script directory, override if needed) |

## Usage Examples

### Basic Call (Primary Only)
```powershell
.\VeeamBR-OffloadCopy.ps1 -BackupJobName "Daily Backup" -PrimaryDestination "\\NAS01\VeeamBackups"
```

### With Alternate Offsite Drives
```powershell
.\VeeamBR-OffloadCopy.ps1 -BackupJobName "Daily Backup" -PrimaryDestination "\\NAS01\VeeamBackups" -AltDestination1 "E:\VeeamBackups" -AltDestination2 "F:\VeeamBackups"
```

### Dry-Run Test
```powershell
.\VeeamBR-OffloadCopy.ps1 -BackupJobName "Daily Backup" -PrimaryDestination "\\NAS01\VeeamBackups" -DryRun
```

### Custom Config File Location
```powershell
.\VeeamBR-OffloadCopy.ps1 -BackupJobName "Daily Backup" -PrimaryDestination "\\NAS01\VeeamBackups" -ConfigFile "D:\Config\VeeamBR-OffloadCopy.json"
```

### From Batch File
```batch
@ECHO OFF
powershell -ExecutionPolicy Bypass ".\VeeamBR-OffloadCopy.ps1 -BackupJobName 'Daily Servers' -PrimaryDestination '\\NAS01\VeeamBackups' -AltDestination1 'E:\VeeamBackups' -AltDestination2 'F:\VeeamBackups'"
```

## Supported Backup Job Types
- Standard Backup Jobs
- NAS Backup Jobs
- Jobs using local repositories (WinLocal)
- Jobs using Scale-Out Backup Repositories (SOBR) with single local extent

## Scheduling via Veeam Job

The recommended approach is to create a batch file for each backup job and configure it as a **Post-job activity script** in Veeam:

1. One batch file per backup job (e.g., `VeeamBR-OffloadCopy_DailyServers.bat`)
2. Each batch file calls the PowerShell script with job-specific parameters
3. Schedule the batch file in Veeam's job settings to run after the backup completes
4. All jobs use the same PowerShell script and shared JSON configuration

This approach allows you to:
- Run different destinations for different backup jobs
- Control which jobs get offloaded
- Easily add or remove jobs from offload operations
- Maintain a single PowerShell script for all offload operations
