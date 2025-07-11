#!/bin/bash
set -euo pipefail

# MariaDB binary log backup - uploads each completed binlog exactly once
# Runs every 15 minutes, emails daily summary, detailed report weekly

# Load configuration
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/backup.conf

LOG_FILE="$MARIADB_BINLOG_LOG"
HOUR=$(date +%H)
DAY_OF_WEEK=$(date +%u)

# Simple logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    logger -t soc2-backup "$1"
}

# Initialize state tracking
initialize_state() {
    mkdir -p "$(dirname "$BINLOG_STATE_FILE")"
    mkdir -p "$(dirname "$BINLOG_DAILY_SUMMARY")"

    # Create state file if it doesn't exist
    if [ ! -f "$BINLOG_STATE_FILE" ]; then
        touch "$BINLOG_STATE_FILE"
        log_message "Created new state tracking file"
    fi
}

# Update daily statistics
update_daily_stats() {
    local uploaded_count=$1
    local uploaded_size=$2
    local status=$3

    local today=$(date +%Y-%m-%d)
    local stats_line="$today $(date +%H:%M) uploaded=$uploaded_count size=$uploaded_size status=$status"

    echo "$stats_line" >> "$BINLOG_DAILY_SUMMARY"
}

log_message "Starting binary log backup check"
START_TIME=$(date +%s)

# Initialize
initialize_state

# Check if MariaDB is running
if ! systemctl is-active --quiet mariadb; then
    log_message "ERROR: MariaDB not running"
    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_binlog status=error error=service_down"
    echo "MariaDB service down on $(hostname) - binary logs not backed up" | mail -s "[BACKUP ERROR] MariaDB Service Down" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1
fi

# Get current binary log (the one being written to)
CURRENT_BINLOG=$(mysql --defaults-file="$MARIADB_DEFAULTS_FILE" -e "SHOW MASTER STATUS\G" 2>/dev/null | grep File | awk '{print $2}')
if [ -z "$CURRENT_BINLOG" ]; then
    log_message "ERROR: Cannot determine current binary log"
    exit 1
fi

log_message "Current binary log: $CURRENT_BINLOG (will not upload)"

# Check if current binary log is getting stale (older than 1 hour)
# This prevents losing too much data during low-activity periods
if [ -f "$BINLOG_DIR/$CURRENT_BINLOG" ]; then
    BINLOG_AGE_MINUTES=$(( ($(date +%s) - $(stat -c %Y "$BINLOG_DIR/$CURRENT_BINLOG")) / 60 ))

    if [ "$BINLOG_AGE_MINUTES" -gt 60 ]; then
        log_message "Current binary log is $BINLOG_AGE_MINUTES minutes old - forcing rotation"

        # Flush logs to create a new binary log file
        if mysql --defaults-file="$MARIADB_DEFAULTS_FILE" -e "FLUSH BINARY LOGS;" 2>/dev/null; then
            log_message "Binary log rotation completed"
            # Give MariaDB a moment to complete the rotation
            sleep 2
        else
            log_message "WARNING: Could not flush binary logs"
        fi
    fi
fi

# Find all binary logs except the current one
cd "$BINLOG_DIR"
AVAILABLE_BINLOGS=$(ls -1 mysql-bin.[0-9]* 2>/dev/null | grep -v "$CURRENT_BINLOG" | sort || true)

if [ -z "$AVAILABLE_BINLOGS" ]; then
    log_message "No completed binary logs found"
    update_daily_stats 0 0 "success"
    exit 0
fi

# Process each completed binary log
UPLOADED_COUNT=0
UPLOADED_SIZE=0
FAILED_COUNT=0

for binlog in $AVAILABLE_BINLOGS; do
    # Check if already uploaded
    if grep -q "^${binlog}$" "$BINLOG_STATE_FILE" 2>/dev/null; then
        continue
    fi

    # This is a new completed binlog - upload it
    log_message "Found new binary log: $binlog"

    # Get file size
    FILE_SIZE=$(stat -c%s "$binlog" 2>/dev/null || echo "0")
    FILE_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B $FILE_SIZE 2>/dev/null || echo "$FILE_SIZE bytes")

    # Upload to S3
    S3_PATH="s3://$AWS_BACKUP_BUCKET/mariadb-binlog/$(hostname)/$(date +%Y/%m)/$binlog"

    if aws s3 cp "$binlog" "$S3_PATH" --only-show-errors; then
        log_message "Uploaded $binlog ($FILE_SIZE_HUMAN)"

        # Record successful upload
        echo "$binlog" >> "$BINLOG_STATE_FILE"
        UPLOADED_COUNT=$((UPLOADED_COUNT + 1))
        UPLOADED_SIZE=$((UPLOADED_SIZE + FILE_SIZE))

        # Log metrics
        logger -t soc2-backup "BINLOG_UPLOADED: file=$binlog size_bytes=$FILE_SIZE"
    else
        log_message "ERROR: Failed to upload $binlog"
        FAILED_COUNT=$((FAILED_COUNT + 1))

        # Send immediate alert for upload failures
        echo "Failed to upload binary log $binlog on $(hostname)" | mail -s "[BACKUP ERROR] Binary Log Upload Failed" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    fi
done

# Calculate duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Update daily statistics
if [ "$FAILED_COUNT" -gt 0 ]; then
    update_daily_stats "$UPLOADED_COUNT" "$UPLOADED_SIZE" "error"
else
    update_daily_stats "$UPLOADED_COUNT" "$UPLOADED_SIZE" "success"
fi

# Log completion metrics
logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_binlog uploaded=$UPLOADED_COUNT failed=$FAILED_COUNT size_bytes=$UPLOADED_SIZE duration_seconds=$DURATION"

# Clean up old state entries for binlogs that no longer exist locally
# (MariaDB has purged them based on retention settings)
if [ -f "$BINLOG_STATE_FILE" ]; then
    TEMP_STATE=$(mktemp)
    while IFS= read -r logged_binlog; do
        if [ -f "$BINLOG_DIR/$logged_binlog" ]; then
            echo "$logged_binlog" >> "$TEMP_STATE"
        fi
    done < "$BINLOG_STATE_FILE"
    mv "$TEMP_STATE" "$BINLOG_STATE_FILE"
fi

# Send daily summary at 8 AM (once per day)
if [ "$HOUR" = "08" ] && [ -f "$BINLOG_DAILY_SUMMARY" ]; then
    # Calculate daily statistics
    TODAY=$(date +%Y-%m-%d)
    YESTERDAY=$(date -d yesterday +%Y-%m-%d)

    TODAY_UPLOADS=$(grep "^$TODAY" "$BINLOG_DAILY_SUMMARY" 2>/dev/null | awk '{sum+=$3} END {print sum+0}' | cut -d= -f2)
    TODAY_SIZE=$(grep "^$TODAY" "$BINLOG_DAILY_SUMMARY" 2>/dev/null | awk '{sum+=$4} END {print sum+0}' | cut -d= -f2)
    TODAY_ERRORS=$(grep "^$TODAY.*status=error" "$BINLOG_DAILY_SUMMARY" 2>/dev/null | wc -l || echo "0")

    YESTERDAY_UPLOADS=$(grep "^$YESTERDAY" "$BINLOG_DAILY_SUMMARY" 2>/dev/null | awk '{sum+=$3} END {print sum+0}' | cut -d= -f2)
    YESTERDAY_SIZE=$(grep "^$YESTERDAY" "$BINLOG_DAILY_SUMMARY" 2>/dev/null | awk '{sum+=$4} END {print sum+0}' | cut -d= -f2)

    # Format sizes
    TODAY_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B ${TODAY_SIZE:-0} 2>/dev/null || echo "0B")
    YESTERDAY_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B ${YESTERDAY_SIZE:-0} 2>/dev/null || echo "0B")

    # Determine status emoji
    if [ "$TODAY_ERRORS" -gt 0 ]; then
        STATUS_EMOJI="⚠️"
    else
        STATUS_EMOJI="✅"
    fi

    # Count total binlogs in S3 for this host
    S3_COUNT=$(aws s3 ls "s3://$AWS_BACKUP_BUCKET/mariadb-binlog/$(hostname)/" --recursive | grep -c "mysql-bin\." || echo "0")

    if [ "$DAY_OF_WEEK" = "1" ]; then
        # Monday - detailed weekly report
        {
            echo "MariaDB Binary Log Weekly Report - $(hostname)"
            echo "Report Date: $(date)"
            echo ""
            echo "This Week's Summary:"
            echo "- Total uploads today: $TODAY_UPLOADS files ($TODAY_SIZE_HUMAN)"
            echo "- Total uploads yesterday: $YESTERDAY_UPLOADS files ($YESTERDAY_SIZE_HUMAN)"
            echo "- Errors today: $TODAY_ERRORS"
            echo "- Total binlogs in S3: $S3_COUNT"
            echo ""
            echo "Storage Details:"
            echo "- S3 path: s3://$AWS_BACKUP_BUCKET/mariadb-binlog/$(hostname)/"
            echo "- Retention: $S3_RETAIN_MARIADB_BINLOG days"
            echo "- Upload frequency: Every 15 minutes"
            echo ""
            echo "How Binary Log Backups Work:"
            echo "1. Every 15 minutes we check for completed binary logs"
            echo "2. Each log is uploaded exactly once to S3"
            echo "3. MariaDB automatically rotates logs when they reach 100MB"
            echo "4. Old logs are purged locally after 7 days"
            echo ""
            echo "Recovery Point Objective (RPO): Maximum 15 minutes"
            echo ""
            echo "To restore transactions after a full backup:"
            echo "1. Restore the latest full backup"
            echo "2. Download binary logs: aws s3 sync s3://$AWS_BACKUP_BUCKET/mariadb-binlog/$(hostname)/ ."
            echo "3. Apply logs: mysqlbinlog mysql-bin.* | mysql"
            echo ""
            echo "Next full backup: Tonight at 2:00 AM UTC"
        } | mail -s "[Backup] Binary Logs Weekly Report - $STATUS_EMOJI $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    else
        # Daily brief summary
        {
            echo "$STATUS_EMOJI MariaDB binary logs on $(hostname)"
            echo ""
            echo "Last 24h: $YESTERDAY_UPLOADS logs uploaded ($YESTERDAY_SIZE_HUMAN)"
            echo "Today so far: $TODAY_UPLOADS logs ($TODAY_SIZE_HUMAN)"
            echo "Total in S3: $S3_COUNT logs | RPO: 15 minutes"
            echo ""
            echo "Full report every Monday."
        } | mail -s "[Backup] Binary Logs - $STATUS_EMOJI $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    fi

    # Rotate daily summary file weekly
    if [ "$DAY_OF_WEEK" = "1" ]; then
        mv "$BINLOG_DAILY_SUMMARY" "${BINLOG_DAILY_SUMMARY}.$(date +%Y%m%d)"
        # Keep only last 4 weeks
        find "$(dirname "$BINLOG_DAILY_SUMMARY")" -name "binlog-daily-stats.txt.*" -mtime +28 -delete 2>/dev/null || true
    fi
fi

log_message "Binary log backup check completed (uploaded: $UPLOADED_COUNT, failed: $FAILED_COUNT)"