#!/bin/bash

# Script to perform mongo db backup
# Accepts positional arguments: single or all
# Author: Subin Gyawali

# Usage: mongobackup.sh [single|all]

# THINGS TO MAKE SURE BEFORE USING THIS SCRIPT

# 1. This script creates zip files for individual database bson contents
    # Be careful while unzipping single db backups
    # Use this commnd to specify destination and prevent scattering of files in the folder
    # unzip -d <UNZIP DIRECTORY NAME> database_timestamp.zip

# List of Databases and respective S3 buckets
# If S3 bucket sync is not required, set an empty string in place of bucket path
# This list has no effect while performing 'all' backup
declare -A DATABASES=(
    [subin]="db-backup-clients/subin"
    [subin_under]="db-backup-clients/subinUnder"
)

# Settings
MONGO_USER="subin"
MONGO_PASS="subin"
MONGO_HOST=localhost
MONGO_PORT=23456
MONGO_AUTH_DB="admin"
MONGO_DUMP="/usr/bin/mongodump"
RETENTION_DAYS="2"
BACKUP_BASE_DIR="/MongoBackups"
LOG_BASE_DIR="/MongoBackupLogs"

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
        $MONGO_DUMP --host $MONGO_HOST --port $MONGO_PORT -d $DB --username $MONGO_USER --password $MONGO_PASS --authenticationDatabase $MONGO_AUTH_DB --out $BACKUP_DIR >> $LOG_BASE_DIR"/mongo_backup.log"
        # Compress backup
        zip -jr "$BACKUP_DIR/$FILE_NAME.zip" "$BACKUP_DIR/$DB" >> $LOG_BASE_DIR"/mongo_backup.log"
        # Remove uncompressed files
        rm -r $BACKUP_DIR/$DB >> $LOG_BASE_DIR"/mongo_backup.log"
        # Sync to S3
        if [[ -n "${DATABASES[$DB]}" ]]
        then
            sudo aws s3 sync $BACKUP_DIR "s3://"${DATABASES[$DB]} >> $LOG_BASE_DIR"/mongo_backup.log"
        fi
        # Remove old files
        find $BACKUP_BASE_DIR/$CLEAN_DB_NAME/* -mtime +$RETENTION_DAYS -delete >> $LOG_BASE_DIR"/mongo_backup.log"
    done
    # Remove old log text
    tail -n 4500 $LOG_BASE_DIR"/mongo_backup.log" > mongotemp.log && mv mongotemp.log $LOG_BASE_DIR"/mongo_backup.log"
else
    # Set backup directory
    BACKUP_DIR=$BACKUP_BASE_DIR"/ALL/"$DATE
    # Set file name
    FILE_NAME="ALL_"$TIMESTAMP
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    # Perform backup
    $MONGO_DUMP --host $MONGO_HOST --port $MONGO_PORT --username $MONGO_USER --password $MONGO_PASS --authenticationDatabase $MONGO_AUTH_DB --out $BACKUP_DIR >> $LOG_BASE_DIR"/mongo_all_backup.log"
    # Compress backup
    cd $BACKUP_DIR; zip -r "$FILE_NAME.zip" . >> $LOG_BASE_DIR"/mongo_all_backup.log"
    # Remove uncompressed folders
    find $BACKUP_DIR/* ! -name '*.zip' -delete >> $LOG_BASE_DIR"/mongo_all_backup.log"
    # Remove old files
    find $BACKUP_BASE_DIR"/ALL/"* -mtime +$RETENTION_DAYS -delete >> $LOG_BASE_DIR"/mongo_all_backup.log"
    # Remove old log text
    tail -n 4500 $LOG_BASE_DIR"/mongo_all_backup.log" > mongoalltemp.log && mv mongoalltemp.log $LOG_BASE_DIR"/mongo_all_backup.log"
fi