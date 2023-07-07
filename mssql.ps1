# Script to perform full, diff and audit backup of SQL Server databases
# Accepts positional arguments: full, diff or audit
# Author: Subin Gyawali (@iamsubingyawali)

# Usage: sqlbackup.ps1 [full|diff|audit]

# THINGS TO MAKE SURE BEFORE USING THIS SCRIPT

# 1. All the spaces, underscores and dashes in database names will be removed on backup directory name and backup file name
# 2. All directory paths should be specified as absolute paths without trailing slashes
# 3. User should specify backup type while calling the script, otherwise full backup will be performed
# 4. The name of the audit backup should follow the pattern: Audit<DBNAME>. DBNAME should have no spaces, dashes or underscores
# 5. The audit folder location should be specified under audit backup settings
# 6. To upload backups to google drive, this script uses 'gdrive' tool which needs to be installed and confiugured before running this script
    # It is available at: https://github.com/glotlabs/gdrive
    # Step 1: Download executable from releases section
    # Step 2: Put executable file somewhere and add that location to system path
    # Step 4: Follow provided guide on readme file to generate OAuth credentials and add an account
# 7. 7Zip Powershell module must be installed to compress backups - Run: Install-Module -Name 7Zip4Powershell

# List of Databases and respective S3 buckets
# If S3 bucket sync is not required, set an empty string in place of bucket path
$DATABASES = @{
    "TestDB1" = "db-backup/TEST"
    "TestDB2" = "db-backup/TEST2"
}

# Common Settings
$MSSQL_USER = "sa"
$MSSQL_PASS = "sa"
$MSSQL_HOST = "localhost"
$MSSQL_PORT = 1433
$SYNC_TO_S3 = $false
$SYNC_TO_GDRIVE = $false

# Date variables
$DATE = Get-Date -Format "yyyy_MM_dd"
$TIMESTAMP = Get-Date -Format "yyyy_MM_dd_HH_mm_ss"

# Default backup type
$TYPE = "full"

# Set backup type
if ($args.Length -gt 0) {
    switch ($args[0]) {
        "diff" { $TYPE = "diff"; break }
        "full" { $TYPE = "full"; break }
        "audit" { $TYPE = "audit"; break }
        default {
            Write-Host "Invalid backup type. Accepted values are 'full', 'diff' and 'audit'."
            exit
        }
    }
}

if ($TYPE -eq "full") {
    # Full backup settings
    $RETENTION_DAYS = "6"
    $BACKUP_BASE_DIR = "/Backups/FullSQLBackups"
    $LOG_BASE_DIR = "/Backups/SQLBackupLogs"
}
elseif ($TYPE -eq "audit") {
    # Audit backup settings
    $RETENTION_DAYS = "6"
    $AUDIT_BASE_FOLDER="/Program Files/Microsoft SQL Server/MSSQL14.SQLEXPRESS/MSSQL/DATA"
    $BACKUP_BASE_DIR = "/Backups/AuditSQLBackups"
    $LOG_BASE_DIR = "/Backups/SQLBackupLogs"
}
else {
    # Differential backup settings
    $RETENTION_DAYS = "1"
    $BACKUP_BASE_DIR = "/Backups/DiffSQLBackups"
    $LOG_BASE_DIR = "/Backups/SQLBackupLogs"
}

# Create base backup and log directories
New-Item -ItemType Directory -Path $BACKUP_BASE_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $LOG_BASE_DIR -Force | Out-Null

# Check if server port is available and create connection string
if($MSSQL_PORT -ne ""){
    $MSSQL_CONN_STRING = "$MSSQL_HOST,$MSSQL_PORT"
}
else{
    $MSSQL_CONN_STRING = $MSSQL_HOST
}

# Perform backups
if ($TYPE -eq "full"){
    foreach ($DB in $DATABASES.Keys) {
        # Get clean db name (replaces _, - and space with nothing)
        $CLEAN_DB_NAME = $DB -replace "[ _-]"
        # Set backup directory
        $BACKUP_DIR = $BACKUP_BASE_DIR + "/" + "$CLEAN_DB_NAME/$DATE"
        # Set file name
        $FILE_NAME = "$CLEAN_DB_NAME" + "_FULL_" + $TIMESTAMP
        # Create backup directory
        New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null
        # Get full backup directory path
        $BACKUP_DIR = Convert-Path $BACKUP_DIR
        # Backup database
        sqlcmd -S $MSSQL_CONN_STRING -U $MSSQL_USER -P $MSSQL_PASS -Q "BACKUP DATABASE [$DB] TO DISK = N'$BACKUP_DIR/$FILE_NAME.bak' WITH NOFORMAT, NOINIT, SKIP, NOREWIND, STATS=10" | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
        Compress-7Zip -Path "$BACKUP_DIR/$FILE_NAME.bak" -ArchiveFileName "$FILE_NAME.zip" -OutputPath "$BACKUP_DIR" | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
        Remove-Item "$BACKUP_DIR/$FILE_NAME.bak" | Out-Null
        # Sync to S3
        $S3_BUCKET_NAME = $DATABASES[$DB]
        if ($S3_BUCKET_NAME -ne "" -and $SYNC_TO_S3) {
            aws s3 sync $BACKUP_DIR "s3://$S3_BUCKET_NAME" | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
        }
        # Sync to Google Drive
        if ($SYNC_TO_GDRIVE) {
            # Check if full backups folder exists
            $DRIVE_BACKUP_FOLDER = gdrive files list --query "name = 'FullSQLBackups'" --field-separator "#_#_#" --skip-header
            if($null -eq $DRIVE_BACKUP_FOLDER){
                $DRIVE_BACKUP_FOLDER = gdrive files mkdir --print-only-id 'FullSQLBackups'
            }
            else {
                $DRIVE_BACKUP_FOLDER = $DRIVE_BACKUP_FOLDER.Split("#_#_#")[0]
            }
            gdrive files upload "$BACKUP_DIR/$FILE_NAME.zip" --parent $DRIVE_BACKUP_FOLDER  | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
        }
        # Add log
        "## $TIMESTAMP FULL BACKUP SUCCESSFUL FOR $DB." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_full_backup.log"
        # Remove old files
        Get-ChildItem $BACKUP_BASE_DIR/$CLEAN_DB_NAME | Where-Object {
            $_.LastWriteTime -lt (Get-Date).AddDays(-$RETENTION_DAYS)
        } | Remove-Item -Recurse -Force
    }
    # Remove old log texts
    Get-Content -Tail 4500 -Path "$LOG_BASE_DIR/mssql_full_backup.log" | Set-Content -Path "$LOG_BASE_DIR/tempfull.log"
    Move-Item -Path "$LOG_BASE_DIR/tempfull.log" -Destination "$LOG_BASE_DIR/mssql_full_backup.log" -Force
}
elseif ($TYPE -eq "audit") {
    foreach ($DB in $DATABASES.Keys) {
        # Check if audit exists
        $AUDIT_FOLDER = $AUDIT_BASE_FOLDER + "/Audit" + ($DB -replace "[ _-]")
        if (Test-Path $AUDIT_FOLDER) {
            # Get clean db name (replaces _, - and space with nothing)
            $CLEAN_DB_NAME = $DB -replace "[ _-]"
            # Set backup directory
            $BACKUP_DIR = $BACKUP_BASE_DIR + "/" + "$CLEAN_DB_NAME/$DATE"
            # Set file name
            $FILE_NAME = "$CLEAN_DB_NAME" + "_AUDIT_" + $TIMESTAMP
            # Create backup directory
            New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null
            # Get full backup directory path
            $BACKUP_DIR = Convert-Path $BACKUP_DIR
            # Zip and move audit folder
            Compress-7Zip -Path ($AUDIT_BASE_FOLDER + "/Audit" + ($DB -replace "[ _-]")) -ArchiveFileName "$FILE_NAME.zip" -OutputPath "$BACKUP_DIR" | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_audit_backup.log"
            # Sync to S3
            if ($DATABASES[$DB] -ne "" -and $SYNC_TO_S3) {
                aws s3 sync $BACKUP_DIR "s3://${DATABASES[$DB]}" | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_audit_backup.log"
            }
            # Sync to Google Drive
            if ($SYNC_TO_GDRIVE) {
                # Check if full backups folder exists
                $DRIVE_BACKUP_FOLDER = gdrive files list --query "name = 'AuditSQLBackups'" --field-separator "#_#_#" --skip-header
                if($null -eq $DRIVE_BACKUP_FOLDER){
                    $DRIVE_BACKUP_FOLDER = gdrive files mkdir --print-only-id 'AuditSQLBackups'
                }
                else {
                    $DRIVE_BACKUP_FOLDER = $DRIVE_BACKUP_FOLDER.Split("#_#_#")[0]
                }
                gdrive files upload "$BACKUP_DIR/$FILE_NAME.zip" --parent $DRIVE_BACKUP_FOLDER  | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_audit_backup.log"
            }
            # Add log
            "## $TIMESTAMP AUDIT BACKUP SUCCESSFUL FOR $DB." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_audit_backup.log"
            # Remove old files
            Get-ChildItem $BACKUP_BASE_DIR/$CLEAN_DB_NAME | Where-Object { 
                $_.LastWriteTime -lt (Get-Date).AddDays(-$RETENTION_DAYS) 
            } | Remove-Item -Recurse -Force
        } else {
            "## $TIMESTAMP NO DATABASE AUDIT FOUND FOR $DB." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_audit_backup.log"
        }
    }
    # Remove old log texts
    Get-Content -Tail 4500 -Path "$LOG_BASE_DIR/mssql_audit_backup.log" | Set-Content -Path "$LOG_BASE_DIR/tempaudit.log"
    Move-Item -Path "$LOG_BASE_DIR/tempaudit.log" -Destination "$LOG_BASE_DIR/mssql_audit_backup.log" -Force
}
else {
    foreach ($DB in $DATABASES.Keys) {
        # Get clean db name (replaces _, - and space with nothing)
        $CLEAN_DB_NAME = $DB -replace "[ _-]"
        # Set backup directory
        $BACKUP_DIR = $BACKUP_BASE_DIR + "/" + "$CLEAN_DB_NAME/$DATE"
        # Set file name
        $FILE_NAME = "$CLEAN_DB_NAME" + "_DIFF_" + $TIMESTAMP
        # Create backup directory
        New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null
        # Get full backup directory path
        $BACKUP_DIR = Convert-Path $BACKUP_DIR
        # Backup Database
        sqlcmd -S $MSSQL_CONN_STRING -U $MSSQL_USER -P $MSSQL_PASS -Q "BACKUP DATABASE [$DB] TO DISK = N'$BACKUP_DIR/$FILE_NAME.bak' WITH DIFFERENTIAL, NOFORMAT, NOINIT, SKIP, NOREWIND, STATS=10" | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_diff_backup.log"
        Compress-7Zip -Path "$BACKUP_DIR/$FILE_NAME.bak" -ArchiveFileName "$FILE_NAME.zip" -OutputPath "$BACKUP_DIR" | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_diff_backup.log"
        Remove-Item "$BACKUP_DIR/$FILE_NAME.bak" | Out-Null
        # Add log
        "## $TIMESTAMP DIFFERENTIAL BACKUP SUCCESSFUL FOR $DB." | Out-File -Encoding "utf8" -Append "$LOG_BASE_DIR/mssql_diff_backup.log"
        # Remove old files
        Get-ChildItem $BACKUP_BASE_DIR/$CLEAN_DB_NAME | Where-Object { 
            $_.LastWriteTime -lt (Get-Date).AddDays(-$RETENTION_DAYS) 
        } | Remove-Item -Recurse -Force
    }
    # Remove old log texts
    Get-Content -Tail 4500 -Path "$LOG_BASE_DIR/mssql_diff_backup.log" | Set-Content -Path "$LOG_BASE_DIR/tempdiff.log"
    Move-Item -Path "$LOG_BASE_DIR/tempdiff.log" -Destination "$LOG_BASE_DIR/mssql_diff_backup.log" -Force
}