#!/bin/bash

# Script to perform postgresql db backup
# Accepts positional arguments: single or all
# Author: Subin Gyawali

# Usage: postgrebackup.sh [single|all]

# THINGS TO MAKE SURE BEFORE USING THIS SCRIPT

# 1. This script creates gzip files for individual database backup contents
    # Be careful while unzipping single db backups
    # Use this commnd to specify destination and prevent scattering of files in the folder
    # sudo mkdir <UNZIP DIRECTORY NAME> | sudo tar -xzf database_timestamp.tar.gz -C <UNZIP DIRECTORY NAME>/

# List of Databases and respective S3 buckets
# If S3 bucket sync is not required, set an empty string in place of bucket path
# This list has no effect while performing 'all' backup
declare -A DATABASES=(
    [postgres]="db-backup-clients/postgres"
    [subin]="db-backup-clients/subin"
    [subin_second]="db-backup-clients/subinSecond"
)

# Settings
PG_USER="postgres"
PG_PASS="postgres"
PG_HOST=localhost
PG_PORT=6789
PG_DUMP_ALL="/usr/bin/pg_dumpall"
PG_DUMP="/usr/bin/pg_dump"
RETENTION_DAYS="2"
BACKUP_BASE_DIR="/PGBackups"
LOG_BASE_DIR="/PGBackupLogs"

# Date variables
DATE=`date +%Y_%m_%d`
TIMESTAMP=`date +%Y_%m_%d_%H_%M_%S`

# Default backup type
TYPE="single"

if [[ -n "$1" ]]
then
    case "$1" in
        "all") TYPE="all" ;;
        "single") TYPE="single" ;;
        *)
            echo "Invalid backup type. Accepted values are 'single' and 'all'."
            exit
        ;;
    esac
fi

# Create base backup and log directories
mkdir -p "$BACKUP_BASE_DIR"
mkdir -p "$LOG_BASE_DIR"

if [[ "$TYPE" == "single" ]]
then
    for DB in ${!DATABASES[@]}; do
        # Get clean db name (replaces _, - and space with nothing)
        CLEAN_DB_NAME=$(echo $DB | sed 's/[ _-]//g')
        # Set backup directory
        BACKUP_DIR=$BACKUP_BASE_DIR/$CLEAN_DB_NAME"/"$DATE
        # Set file name
        FILE_NAME=$CLEAN_DB_NAME"_"$TIMESTAMP
        # Create backup directory
        mkdir -p "$BACKUP_DIR"
        # Perform backup
        PGPASSWORD=$PG_PASS $PG_DUMP --host $PG_HOST --port $PG_PORT --username $PG_USER --file $BACKUP_DIR/$FILE_NAME.tar -F t $DB >> $LOG_BASE_DIR"/pg_backup.log"
        # Compress backup
        cd $BACKUP_DIR; gzip "$FILE_NAME.tar" >> $LOG_BASE_DIR"/pg_backup.log"
        # Sync to S3
        if [[ -n "${DATABASES[$DB]}" ]]
        then
            sudo aws s3 sync $BACKUP_DIR "s3://"${DATABASES[$DB]} >> $LOG_BASE_DIR"/pg_backup.log"
        fi
        # Remove old files
        find $BACKUP_BASE_DIR/$CLEAN_DB_NAME/* -mtime +$RETENTION_DAYS -delete >> $LOG_BASE_DIR"/pg_backup.log"
    done
    # Remove old log text
    tail -n 4500 $LOG_BASE_DIR"/pg_backup.log" > pgtemp.log && mv pgtemp.log $LOG_BASE_DIR"/pg_backup.log"
else
    # Set backup directory
    BACKUP_DIR=$BACKUP_BASE_DIR"/ALL/"$DATE
    # Set file name
    FILE_NAME="ALL_"$TIMESTAMP
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    # Perform backup
    PGPASSWORD=$PG_PASS $PG_DUMP_ALL --host $PG_HOST --port $PG_PORT --username $PG_USER --file $BACKUP_DIR/$FILE_NAME.sql >> $LOG_BASE_DIR"/pg_all_backup.log"
    # Compress backup
    zip -j "$BACKUP_DIR/$FILE_NAME.zip" $BACKUP_DIR/$FILE_NAME.sql >> $LOG_BASE_DIR"/pg_all_backup.log"
    # Remove uncompressed backup file
    rm $BACKUP_DIR/$FILE_NAME.sql >> $LOG_BASE_DIR"/pg_all_backup.log"
    # Remove old files
    find $BACKUP_BASE_DIR"/ALL/"* -mtime +$RETENTION_DAYS -delete >> $LOG_BASE_DIR"/pg_all_backup.log"
    # Remove old log text
    tail -n 4500 $LOG_BASE_DIR"/pg_all_backup.log" > pgalltemp.log && mv pgalltemp.log $LOG_BASE_DIR"/pg_all_backup.log"
fi