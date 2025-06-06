#!/bin/bash
set -euo pipefail

# MariaDB backup script with local retention and AWS staging
# Runs hourly, keeps 7 days local, stages for AWS upload

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/mariadb-backup.conf

LOG_FILE="/var/log/backups/mariadb-backup.log"
DATE_STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_BASE/mariadb"
STAGING_DIR="$BACKUP_BASE/aws-staging/mariadb"

# Datadog-friendly logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    logger -t mariadb-backup "$1"
}

# Create directories if they don't exist
mkdir -p "$BACKUP_DIR" "$STAGING_DIR"

log_message "Starting MariaDB backup - $DATE_STAMP"

# Check if MariaDB is running
if ! systemctl is-active --quiet mariadb; then
    log_message "ERROR: MariaDB service not running"
    echo "MariaDB backup failed - service not running on $(hostname)" | mail -s "[BACKUP ERROR] MariaDB Service Down" "$ADMIN_EMAIL"
    exit 1
fi

# Create backup using mariadb-backup
BACKUP_PATH="$BACKUP_DIR/backup-$DATE_STAMP"
BACKUP_START=$(date +%s)

log_message "Creating backup: $BACKUP_PATH"

if mariadb-backup --backup \
    --user="$MARIADB_USER" \
    --password="$MARIADB_ADMIN_PASSWORD" \
    --target-dir="$BACKUP_PATH" \
    --compress \
    --compress-threads=2 2>&1 | tee -a "$LOG_FILE"; then

    BACKUP_STATUS="success"
    log_message "Backup completed successfully"
else
    BACKUP_STATUS="failed"
    log_message "ERROR: Backup failed"
    echo "MariaDB backup failed on $(hostname) at $(date)" | mail -s "[BACKUP ERROR] MariaDB Backup Failed" "$ADMIN_EMAIL"
    exit 1
fi

BACKUP_END=$(date +%s)
BACKUP_DURATION=$((BACKUP_END - BACKUP_START))
BACKUP_SIZE=$(du -sh "$BACKUP_PATH" | cut -f1)

# Log structured metrics for Datadog
logger -t mariadb-backup "BACKUP_COMPLETE: status=$BACKUP_STATUS duration=${BACKUP_DURATION}s size=$BACKUP_SIZE path=$BACKUP_PATH"

# Clean up old local backups (keep last 168 hours = 7 days)
log_message "Cleaning up old local backups"
find "$BACKUP_DIR" -name "backup-*" -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null || true

# Stage daily backups for AWS upload (only at midnight)
CURRENT_HOUR=$(date +%H)
if [ "$CURRENT_HOUR" = "00" ]; then
    log_message "Staging backup for AWS upload"

    # Create compressed archive for AWS
    ARCHIVE_NAME="mariadb-daily-$(date +%Y%m%d).tar.gz"
    ARCHIVE_PATH="$STAGING_DIR/$ARCHIVE_NAME"

    if tar -czf "$ARCHIVE_PATH" -C "$BACKUP_DIR" "backup-$DATE_STAMP"; then
        log_message "AWS staging completed: $ARCHIVE_PATH"
        logger -t mariadb-backup "AWS_STAGED: archive=$ARCHIVE_NAME size=$(du -sh "$ARCHIVE_PATH" | cut -f1)"
    else
        log_message "ERROR: AWS staging failed"
        echo "MariaDB AWS staging failed on $(hostname)" | mail -s "[BACKUP ERROR] AWS Staging Failed" "$ADMIN_EMAIL"
    fi
fi

# Count local backups for monitoring
LOCAL_BACKUPS=$(find "$BACKUP_DIR" -name "backup-*" -type d | wc -l)
log_message "Local retention: $LOCAL_BACKUPS backups stored"

# Send success notification
{
    echo "MariaDB backup completed successfully on $(hostname)"
    echo ""
    echo "Backup Details:"
    echo "- Timestamp: $DATE_STAMP"
    echo "- Duration: ${BACKUP_DURATION} seconds"
    echo "- Size: $BACKUP_SIZE"
    echo "- Local backups: $LOCAL_BACKUPS"
    echo ""
    echo "Backup location: $BACKUP_PATH"
    echo "View backup metrics in your Datadog dashboard."
} | mail -s "[Backup] MariaDB Backup - Success - $(hostname)" "$ADMIN_EMAIL"

log_message "MariaDB backup completed successfully"