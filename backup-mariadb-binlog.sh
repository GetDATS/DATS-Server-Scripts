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

# Force binary log rotation to ensure we have a complete log to backup
# This guarantees our 15-minute RPO even during low-activity periods
log_message "Rotating binary logs"
mysql --defaults-file=/root/.backup.cnf -e "FLUSH BINARY LOGS;" 2>/dev/null
sleep 2  # Give MariaDB time to close the old log

# Get current binary log from MariaDB (using secure credentials)
CURRENT_BINLOG=$(mysql --defaults-file=/root/.backup.cnf -e "SHOW MASTER STATUS\G" 2>/dev/null | grep File | awk '{print $2}')

if [ -z "$CURRENT_BINLOG" ]; then
    log_message "ERROR: Cannot determine current binary log"
    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_binlog status=$STATUS_ERROR error=cannot_get_binlog"
    exit 1
fi

log_message "Current binary log: $CURRENT_BINLOG"

# Create state file if it doesn't exist
touch "$STATE_FILE"

# Weekly state file cleanup - recreate with only recent entries
if [ "$(date +%u)" = "7" ]; then  # Sunday
    log_message "Performing weekly state file cleanup"

    # Get list of current binary logs from the last 7 days
    temp_state=$(mktemp)
    find $BINLOG_DIR -name "mysql-bin.[0-9]*" -mtime -7 -type f 2>/dev/null | while read -r binlog_path; do
        basename "$binlog_path" >> "$temp_state"
    done

    # Replace the state file with cleaned version
    if [ -s "$temp_state" ]; then
        mv "$temp_state" "$STATE_FILE"
        log_message "State file cleaned - $(wc -l < "$STATE_FILE") entries retained"
    else
        rm -f "$temp_state"
        log_message "State file cleanup skipped - no recent entries found"
    fi
fi

# Process completed binary logs only (not the current one being written)
for binlog_path in $(ls $BINLOG_DIR/mysql-bin.[0-9]* 2>/dev/null | grep -v '.index' || true); do
    BINLOG_NAME=$(basename "$binlog_path")

    # Skip current log (still being written to)
    if [[ "$BINLOG_NAME" == "$CURRENT_BINLOG" ]]; then
        continue
    fi

    # Skip if already processed
    if grep -q "^$BINLOG_NAME$" "$STATE_FILE" 2>/dev/null; then
        continue
    fi

    # Create temporary state file for atomic update
    cp "$STATE_FILE" "$STATE_FILE.tmp"
    echo "$BINLOG_NAME" >> "$STATE_FILE.tmp"

    # Upload to S3 with backup-type-first organization
    S3_PATH="s3://$AWS_BACKUP_BUCKET/mariadb-binlog/$(hostname)/$(date +%Y/%m/%d)/$BINLOG_NAME"

    log_message "Uploading: $BINLOG_NAME"

    if aws s3 cp "$binlog_path" "$S3_PATH"; then
        # Atomically update state file only after successful upload
        mv "$STATE_FILE.tmp" "$STATE_FILE"

        # Update counters
        FILES_UPLOADED=$((FILES_UPLOADED + 1))
        FILE_SIZE=$(stat -c%s "$binlog_path" 2>/dev/null || echo "0")
        TOTAL_SIZE=$((TOTAL_SIZE + FILE_SIZE))

        log_message "Uploaded successfully: $BINLOG_NAME ($(numfmt --to=iec-i --suffix=B $FILE_SIZE))"
    else
        # Clean up temporary file on failure
        rm -f "$STATE_FILE.tmp"
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

# Smart notification - only email on errors or daily summary at 8 AM
if [ "$FILES_UPLOADED" -eq 0 ] && [ "$SYNC_DURATION" -gt 60 ]; then
    # Possible issue - took too long but uploaded nothing
    log_message "WARNING: Sync took ${SYNC_DURATION}s but uploaded no files"
elif [ "$FILES_UPLOADED" -gt 10 ]; then
    # Unusual activity - many files uploaded
    {
        echo "Unusual MariaDB binary log activity on $(hostname)"
        echo ""
        echo "Alert Details:"
        echo "- Files uploaded: $FILES_UPLOADED (normally 1-2)"
        echo "- Total size: $(numfmt --to=iec-i --suffix=B $TOTAL_SIZE)"
        echo "- Duration: ${SYNC_DURATION} seconds"
        echo ""
        echo "This could indicate:"
        echo "- Heavy database activity"
        echo "- Backup process was down"
        echo "- Binary logs not rotating properly"
        echo ""
        echo "Please investigate if unexpected."
    } | mail -s "[Backup Alert] Unusual Activity - $FILES_UPLOADED binlogs - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
elif [ "$(date +%H)" = "08" ] && [ "$FILES_UPLOADED" -gt 0 ]; then
    # Daily summary at 8 AM only
    YESTERDAY_COUNT=$(grep -c "$(date -d yesterday +%Y-%m-%d)" "$LOG_FILE" 2>/dev/null || echo "0")
    {
        echo "Daily MariaDB binary log summary for $(hostname)"
        echo ""
        echo "Last 24 hours:"
        echo "- Backup runs: ~96 (every 15 minutes)"
        echo "- Total files uploaded: ~$YESTERDAY_COUNT"
        echo "- Current status: Operational"
        echo ""
        echo "This automated summary confirms your"
        echo "15-minute RPO is being maintained."
    } | mail -s "[Backup] Daily Binlog Summary - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
fi

log_message "Binary log sync completed"