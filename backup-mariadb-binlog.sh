#!/bin/bash
set -euo pipefail

# Load configuration
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/backup.conf

LOG_FILE="/var/log/backups/mariadb-binlog.log"

# Structured logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    logger -t soc2-backup "$1"
}

log_message "Starting MariaDB binary log sync"
SYNC_START=$(date +%s)

# Step 1: Flush logs to ensure we have complete binlogs
# This rotates the current log so we're not syncing an active file
log_message "Flushing binary logs"
if ! mysql --defaults-file=/root/.backup.cnf -e "FLUSH BINARY LOGS;" 2>/dev/null; then
    log_message "ERROR: Cannot flush binary logs"
    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_binlog status=$STATUS_ERROR error=flush_failed"
    exit 1
fi

# Give MariaDB a moment to finish the rotation
sleep 2

# Step 2: Get current binlog so we can exclude it from sync
CURRENT_BINLOG=$(mysql --defaults-file=/root/.backup.cnf -e "SHOW MASTER STATUS\G" 2>/dev/null | grep File | awk '{print $2}')
log_message "Current binary log (will not sync): $CURRENT_BINLOG"

# Step 3: Create exclude pattern for aws sync
TEMP_EXCLUDE=$(mktemp)
echo "$CURRENT_BINLOG" > "$TEMP_EXCLUDE"
echo "*.index" >> "$TEMP_EXCLUDE"  # Don't sync the index file

# Step 4: Run the sync
log_message "Syncing binary logs to S3"
SYNC_OUTPUT=$(aws s3 sync \
    "$BINLOG_DIR" \
    "s3://$AWS_BACKUP_BUCKET/mariadb-binlog/$(hostname)/$(date +%Y/%m)/" \
    --exclude "*" \
    --include "mysql-bin.[0-9]*" \
    --exclude-from "$TEMP_EXCLUDE" \
    --size-only \
    --delete \
    2>&1)

SYNC_EXIT=$?
SYNC_END=$(date +%s)
SYNC_DURATION=$((SYNC_END - SYNC_START))

# Clean up
rm -f "$TEMP_EXCLUDE"

# Parse sync output for metrics
UPLOADED_COUNT=$(echo "$SYNC_OUTPUT" | grep -c "upload:" || echo "0")
DELETED_COUNT=$(echo "$SYNC_OUTPUT" | grep -c "delete:" || echo "0")

# Log results
if [ $SYNC_EXIT -eq 0 ]; then
    log_message "Sync completed: $UPLOADED_COUNT uploaded, $DELETED_COUNT deleted"
    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_binlog files_uploaded=$UPLOADED_COUNT files_deleted=$DELETED_COUNT status=$STATUS_SUCCESS duration_seconds=$SYNC_DURATION"
else
    log_message "ERROR: Sync failed with exit code $SYNC_EXIT"
    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_binlog status=$STATUS_ERROR error=sync_failed duration_seconds=$SYNC_DURATION"

    # Send alert for sync failures
    echo "MariaDB binlog sync failed on $(hostname). Check logs: $LOG_FILE" | \
        mail -s "[BACKUP ERROR] Binlog Sync Failed - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
fi

# Only send email on issues or daily summary
if [ $UPLOADED_COUNT -gt 10 ] || [ $DELETED_COUNT -gt 50 ]; then
    log_message "Unusual sync activity detected"
    echo "Unusual binlog sync activity on $(hostname): $UPLOADED_COUNT uploaded, $DELETED_COUNT deleted" | \
        mail -s "[BACKUP ALERT] Unusual Binlog Activity - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
fi

log_message "Binary log sync completed"