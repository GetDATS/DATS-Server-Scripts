#!/bin/bash
set -euo pipefail

# MariaDB binary log backup - ships transaction logs for point-in-time recovery
# Runs every 15 minutes to maintain low recovery point objective (RPO)

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/backup.conf

LOG_FILE="/var/log/backups/mariadb-binlog.log"
STATE_FILE="/var/lib/backup-state/processed-binlogs"

# Structured logging function for monitoring integration
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    logger -t soc2-backup "$1"
}

# Log structured metrics for monitoring
log_metrics() {
    local files_uploaded=$1
    local total_size=$2
    local status=$3
    local operation_duration=${4:-0}

    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_binlog files_uploaded=$files_uploaded size_bytes=$total_size status=$status duration_seconds=$operation_duration"
}

log_message "Starting MariaDB binary log sync"
SYNC_START=$(date +%s)

# Initialize counters
FILES_UPLOADED=0
TOTAL_SIZE=0

# Get current binary log from MariaDB
CURRENT_BINLOG=$(mysql -u "$MARIADB_BACKUP_USER" -p"$MARIADB_ADMIN_PASSWORD" -e "SHOW MASTER STATUS\G" 2>/dev/null | grep File | awk '{print $2}')

if [ -z "$CURRENT_BINLOG" ]; then
    log_message "ERROR: Cannot determine current binary log"
    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_binlog status=$STATUS_ERROR error=cannot_get_binlog"
    exit 1
fi

log_message "Current binary log: $CURRENT_BINLOG"

# Process completed binary logs only (not the current one being written)
for binlog_path in $(ls $BINLOG_DIR/mysql-bin.[0-9]* 2>/dev/null | grep -v '.index || true); do
    BINLOG_NAME=$(basename "$binlog_path")
    
    # Skip current log (still being written to)
    if [[ "$BINLOG_NAME" == "$CURRENT_BINLOG" ]]; then
        continue
    fi
    
    # Skip if already processed
    if grep -q "^$BINLOG_NAME$" "$STATE_FILE" 2>/dev/null; then
        continue
    fi
    
    # Upload to S3 with backup-type-first organization
    S3_PATH="s3://$AWS_BACKUP_BUCKET/mariadb-binlog/$(hostname)/$(date +%Y/%m/%d)/$BINLOG_NAME"
    
    log_message "Uploading: $BINLOG_NAME"
    
    if aws s3 cp "$binlog_path" "$S3_PATH"; then
        # Record as processed
        echo "$BINLOG_NAME" >> "$STATE_FILE"
        
        # Update counters
        FILES_UPLOADED=$((FILES_UPLOADED + 1))
        FILE_SIZE=$(stat -c%s "$binlog_path" 2>/dev/null || echo "0")
        TOTAL_SIZE=$((TOTAL_SIZE + FILE_SIZE))
        
        log_message "Uploaded successfully: $BINLOG_NAME ($(numfmt --to=iec-i --suffix=B $FILE_SIZE))"
    else
        log_message "ERROR: Failed to upload $BINLOG_NAME"
        logger -t soc2-security "BACKUP_FAILURE: service=mariadb-binlog file=$BINLOG_NAME severity=high"
    fi
done

SYNC_END=$(date +%s)
SYNC_DURATION=$((SYNC_END - SYNC_START))

# Determine status based on results
if [ "$FILES_UPLOADED" -gt 0 ]; then
    SYNC_STATUS="$STATUS_SUCCESS"
    log_message "Binary log sync completed - $FILES_UPLOADED files uploaded"
else
    SYNC_STATUS="$STATUS_SUCCESS"  # No new logs is still success
    log_message "Binary log sync completed - no new logs to upload"
fi

# Log structured metrics
log_metrics "$FILES_UPLOADED" "$TOTAL_SIZE" "$SYNC_STATUS" "$SYNC_DURATION"

# Send notification only if files were uploaded (avoid spam)
if [ "$FILES_UPLOADED" -gt 0 ]; then
    {
        echo "MariaDB binary log sync completed on $(hostname)"
        echo ""
        echo "Sync Summary:"
        echo "- Files uploaded: $FILES_UPLOADED"
        echo "- Total size: $(numfmt --to=iec-i --suffix=B $TOTAL_SIZE 2>/dev/null || echo "$TOTAL_SIZE bytes")"
        echo "- Duration: ${SYNC_DURATION} seconds"
        echo ""
        echo "These binary logs enable point-in-time recovery"
        echo "between full backups (15-minute RPO)."
        echo ""
        echo "Retention: $RETAIN_MARIADB_BINLOG days"
    } | mail -s "[Backup] MariaDB Binlog - $FILES_UPLOADED logs uploaded - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
fi

log_message "Binary log sync completed"