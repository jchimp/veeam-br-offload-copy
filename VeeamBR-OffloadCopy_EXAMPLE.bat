@ECHO OFF

powershell -ExecutionPolicy Bypass ".\VeeamBR-OffloadCopy.ps1 -BackupJobName 'BACKUP-JOB-NAME' -PrimaryDestination '\\NAS01\VeeamBackups' -AltDestination1 'E:\VeeamBackups' -AltDestination2 'F:\VeeamBackups'"
