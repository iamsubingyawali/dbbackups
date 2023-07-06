#!/bin/bash

# Script to perform full, diff and audit backup of SQL Server databases
# Accepts positional arguments: full, diff or audit
# Author: Subin Gyawali (@iamsubingyawali)

# Usage: sqlbackup.sh [full|diff|audit]

# THINGS TO MAKE SURE BEFORE USING THIS SCRIPT

# 1. All the spaces, underscores and dashes in database names will be removed on backup directory name and backup file name
# 2. All directory paths should be specified as absolute paths without trailing slashes
# 3. User should specify backup type while calling the script, otherwise full backup will be performed
# 4. The name of the audit backup should follow the pattern: Audit<DBNAME>. DBNAME should have no spaces, dashes or underscores
# 5. The audit folder location should be /var/opt/mssql/data/AuditFolder

# List of Databases and respective S3 buckets
# If S3 bucket sync is not required, set an empty string in place of bucket path
declare -A DATABASES=(
    [TESTDB_1]="db-backup/TESTDB1"
    [TESTDB_2]="db-backup/TESTDB2"
)

# Common Settings
MSSQL_USER="sa"
MSSQL_PASS="sa"
MSSQL_HOST=localhost
MSSQL_PORT=1433
SQLCMD=/opt/mssql-tools/bin/sqlcmd

# Date variables
DATE=`date +%Y_%m_%d`
TIMESTAMP=`date +%Y_%m_%d_%H_%M_%S`

# Default backup type
TYPE="full"

if [[ -n "$1" ]]
then
    case "$1" in
        "diff") TYPE="diff" ;;
        "full") TYPE="full" ;;
        "audit") TYPE="audit" ;;
        *)
            echo "Invalid backup type. Accepted values are 'full', 'diff' and 'audit'."
            exit
        ;;
    esac
fi

if [[ "$TYPE" == "full" ]]
then
    # Full backup settings
    RETENTION_DAYS="6"
    BACKUP_BASE_DIR="/FullSQLBackups"
    LOG_BASE_DIR="/SQLBackupLogs"
elif [[ "$TYPE" == "audit" ]]
then
    # Audit backup settings
    RETENTION_DAYS="6"
    BACKUP_BASE_DIR="/AuditSQLBackups"
    LOG_BASE_DIR="/SQLBackupLogs"
else
    # Differential backup settings
    RETENTION_DAYS="1"
    BACKUP_BASE_DIR="/DiffSQLBackups"
    LOG_BASE_DIR="/SQLBackupLogs"
fi

# Create base backup and log directories
mkdir -p "$BACKUP_BASE_DIR"
mkdir -p "$LOG_BASE_DIR"

# Adjust directory permissions
chown mssql:root "$BACKUP_BASE_DIR"
chown mssql:root "$LOG_BASE_DIR"

if [[ "$TYPE" == "full" ]]
then
    for DB in ${!DATABASES[@]}; do
        # Get clean db name (replaces _, - and space with nothing)
        CLEAN_DB_NAME=$(echo $DB | sed 's/[ _-]//g')
        # Set backup directory
        BACKUP_DIR=$BACKUP_BASE_DIR/$CLEAN_DB_NAME"/"$DATE
        # Set file name
        FILE_NAME=$CLEAN_DB_NAME"_FULL_"$TIMESTAMP
        # Create backup directory
        mkdir -p "$BACKUP_DIR"
        # Adjust directory permisions
        chown mssql:root $BACKUP_DIR
        # Backup Database
        $SQLCMD -S $MSSQL_HOST,$MSSQL_PORT -Q "BACKUP DATABASE [$DB] TO DISK = N'$BACKUP_DIR/$FILE_NAME.bak' WITH NOFORMAT, NOINIT, SKIP, NOREWIND, STATS=10" -U $MSSQL_USER -P $MSSQL_PASS >> $LOG_BASE_DIR"/mssql_full_backup.log"
        zip -j "$BACKUP_DIR/$FILE_NAME.zip" "$BACKUP_DIR/$FILE_NAME.bak" >> $LOG_BASE_DIR"/mssql_full_backup.log"
        rm "$BACKUP_DIR/$FILE_NAME.bak"
        # Sync to S3
        if [[ -n "${DATABASES[$DB]}" ]]
        then
            sudo aws s3 sync $BACKUP_DIR "s3://"${DATABASES[$DB]} >> $LOG_BASE_DIR"/mssql_full_backup.log"
        fi
        # Add log
        echo "## $TIMESTAMP FULL BACKUP SUCCESSFUL FOR $DB." >> $LOG_BASE_DIR"/mssql_full_backup.log"
        # Remove old files
        find $BACKUP_BASE_DIR/$CLEAN_DB_NAME/* -mtime +$RETENTION_DAYS -delete
    done
    # Remove old log text
    tail -n 4500 $LOG_BASE_DIR"/mssql_full_backup.log" > tempfull.log && mv tempfull.log $LOG_BASE_DIR"/mssql_full_backup.log"
elif [[ "$TYPE" == "audit" ]]
then
    for DB in ${!DATABASES[@]}; do
        # Check if audit exists
        AUDIT_FOLDER="/var/opt/mssql/data/Audit"$(echo $DB | sed 's/[ _-]//g')
        if [[ -d  $AUDIT_FOLDER ]]
        then
            # Get clean db name (replaces _, - and space with nothing)
            CLEAN_DB_NAME=$(echo $DB | sed 's/[ _-]//g')
            # Set backup directory
            BACKUP_DIR=$BACKUP_BASE_DIR/$CLEAN_DB_NAME"/"$DATE
            # Set file name
            FILE_NAME=$CLEAN_DB_NAME"_AUDIT_"$TIMESTAMP
            # Create backup directory
            mkdir -p "$BACKUP_DIR"
            # Adjust directory permisions
            chown mssql:root $BACKUP_DIR
            # Zip and move audit folder
            cd /var/opt/mssql/data; zip -r $FILE_NAME.zip Audit$(echo $DB | sed 's/[ _-]//g') >> $LOG_BASE_DIR"/mssql_audit_backup.log"
            mv $FILE_NAME.zip $BACKUP_DIR
            # Sync to S3
            if [[ -n "${DATABASES[$DB]}" ]]
            then
                sudo aws s3 sync $BACKUP_DIR "s3://"${DATABASES[$DB]} >> $LOG_BASE_DIR"/mssql_audit_backup.log"
            fi
            # Add log
            echo "## $TIMESTAMP AUDIT BACKUP SUCCESSFUL FOR $DB." >> $LOG_BASE_DIR"/mssql_audit_backup.log"
            # Remove old files
            find $BACKUP_BASE_DIR/$CLEAN_DB_NAME/* -mtime +$RETENTION_DAYS -delete
        else
            echo "## $TIMESTAMP NO DATABASE AUDIT FOUND FOR $DB." >> $LOG_BASE_DIR"/mssql_audit_backup.log"
        fi
    done
    # Remove old log text
    tail -n 4500 $LOG_BASE_DIR"/mssql_audit_backup.log" > tempaudit.log && mv tempaudit.log $LOG_BASE_DIR"/mssql_audit_backup.log"
else
    for DB in ${!DATABASES[@]}; do
        # Get clean db name (replaces _, - and space with nothing)
        CLEAN_DB_NAME=$(echo $DB | sed 's/[ _-]//g')
        # Set backup directory
        BACKUP_DIR=$BACKUP_BASE_DIR/$CLEAN_DB_NAME"/"$DATE
        # Set file name
        FILE_NAME=$CLEAN_DB_NAME"_DIFF_"$TIMESTAMP
        # Create backup directory
        mkdir -p "$BACKUP_DIR"
        # Adjust directory permisions
        chown mssql:root $BACKUP_DIR
        # Backup Database
        $SQLCMD -S $MSSQL_HOST,$MSSQL_PORT -Q "BACKUP DATABASE [$DB] TO DISK = N'$BACKUP_DIR/$FILE_NAME.bak' WITH DIFFERENTIAL, NOFORMAT, NOINIT, SKIP, NOREWIND, STATS=10" -U $MSSQL_USER -P $MSSQL_PASS >> $LOG_BASE_DIR"/mssql_diff_backup.log"
        zip -j "$BACKUP_DIR/$FILE_NAME.zip" "$BACKUP_DIR/$FILE_NAME.bak" >> $LOG_BASE_DIR"/mssql_diff_backup.log"
        rm "$BACKUP_DIR/$FILE_NAME.bak"
        # Add log
        echo "## $TIMESTAMP DIFFERENTIAL BACKUP SUCCESSFUL FOR $DB." >> $LOG_BASE_DIR"/mssql_diff_backup.log"
        # Remove old files
        find $BACKUP_BASE_DIR/$CLEAN_DB_NAME/* -mtime +$RETENTION_DAYS -delete
        # Remove empty directories
        find $BACKUP_BASE_DIR/$CLEAN_DB_NAME/* -empty -type d -delete
    done
    # Remove old log text
    tail -n 4500 $LOG_BASE_DIR"/mssql_diff_backup.log" > tempdiff.log && mv tempdiff.log $LOG_BASE_DIR"/mssql_diff_backup.log"
fi