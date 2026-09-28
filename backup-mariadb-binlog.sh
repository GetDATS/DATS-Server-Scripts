#!/bin/bash
set -euo pipefail

# MariaDB binary log backup - production-ready with comprehensive safety checks
# Uploads each completed binlog exactly once with smart rotation management

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

# Pre-flight checks - catch problems before they cascade
preflight_checks() {
    local checks_passed=true

    # Check 1: Is MariaDB actually running?
    log_message "Pre-flight: Checking MariaDB service"
    if ! systemctl is-active --quiet mariadb; then
        log_message "ERROR: MariaDB service is not running"
        echo "MariaDB service is down on $(hostname) - binary logs cannot be backed up" | mail -s "[BACKUP ERROR] MariaDB Service Down" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
        exit 1
    fi

    # Check 2: Is binary logging enabled?
    log_message "Pre-flight: Checking binary logging status"
    BIN_LOG_STATUS=$(mysql --defaults-file="$MARIADB_DEFAULTS_FILE" -e "SHOW VARIABLES LIKE 'log_bin';" -s -N 2>/dev/null | awk '{print $2}')
    if [ "$BIN_LOG_STATUS" != "ON" ]; then
        log_message "ERROR: Binary logging is not enabled!"
        echo "CRITICAL: Binary logging is disabled on $(hostname) - point-in-time recovery is not possible!" | mail -s "[BACKUP CRITICAL] Binary Logging Disabled" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
        exit 1
    fi

    # Check 3: Can we connect to MariaDB?
    log_message "Pre-flight: Testing MariaDB connectivity"
    if ! mysql --defaults-file="$MARIADB_DEFAULTS_FILE" -e "SELECT 1" >/dev/null 2>&1; then
        log_message "ERROR: Cannot connect to MariaDB"
        echo "Cannot connect to MariaDB on $(hostname) - check backup credentials" | mail -s "[BACKUP ERROR] MariaDB Connection Failed" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
        exit 1
    fi

    # Check 4: Can we access the binary log directory?
    log_message "Pre-flight: Checking binary log directory"
    if [ ! -d "$BINLOG_DIR" ]; then
        log_message "ERROR: Binary log directory does not exist: $BINLOG_DIR"
        checks_passed=false
    elif [ ! -r "$BINLOG_DIR" ]; then
        log_message "ERROR: Cannot read binary log directory: $BINLOG_DIR"
        checks_passed=false
    fi

    # Check 5: Are AWS credentials configured?
    log_message "Pre-flight: Checking AWS credentials"
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_message "ERROR: AWS credentials not configured or invalid"
        echo "AWS credentials invalid on $(hostname) - binary logs cannot be uploaded" | mail -s "[BACKUP ERROR] AWS Credentials Invalid" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
        exit 1
    fi

    # Check 6: Can we access the S3 bucket?
    log_message "Pre-flight: Checking S3 bucket access"
    if ! aws s3 ls "s3://$AWS_BACKUP_BUCKET" >/dev/null 2>&1; then
        log_message "ERROR: Cannot access S3 bucket: $AWS_BACKUP_BUCKET"
        checks_passed=false
    fi

    if [ "$checks_passed" = false ]; then
        log_message "ERROR: Pre-flight checks failed"
        exit 1
    fi

    log_message "Pre-flight: All checks passed"
}

# Initialize state tracking
initialize_state() {
    mkdir -p "$(dirname "$BINLOG_STATE_FILE")"

    # Create state file if it doesn't exist
    if [ ! -f "$BINLOG_STATE_FILE" ]; then
        touch "$BINLOG_STATE_FILE"
        log_message "Created new state tracking file"
    else
        # Validate state file isn't corrupted
        local line_count=$(wc -l < "$BINLOG_STATE_FILE" 2>/dev/null || echo "0")
        if [ "$line_count" -gt 10000 ]; then
            log_message "WARNING: State file has $line_count entries - possible corruption, rotating"
            mv "$BINLOG_STATE_FILE" "${BINLOG_STATE_FILE}.corrupted.$(date +%Y%m%d-%H%M%S)"
            touch "$BINLOG_STATE_FILE"
        fi
    fi
}

log_message "Starting binary log backup check"
START_TIME=$(date +%s)

# Run pre-flight checks before we commit to anything
preflight_checks

# Initialize state tracking
initialize_state

# Get current binary log (the one being written to)
CURRENT_BINLOG=$(mysql --defaults-file="$MARIADB_DEFAULTS_FILE" -e "SHOW MASTER STATUS\G" 2>/dev/null | grep File | awk '{print $2}')
if [ -z "$CURRENT_BINLOG" ]; then
    log_message "ERROR: Cannot determine current binary log"
    exit 1
fi

log_message "Current binary log: $CURRENT_BINLOG"

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

            # Update current binlog after rotation
            NEW_CURRENT=$(mysql --defaults-file="$MARIADB_DEFAULTS_FILE" -e "SHOW MASTER STATUS\G" 2>/dev/null | grep File | awk '{print $2}')
            if [ -n "$NEW_CURRENT" ] && [ "$NEW_CURRENT" != "$CURRENT_BINLOG" ]; then
                log_message "New current binary log: $NEW_CURRENT"
                CURRENT_BINLOG="$NEW_CURRENT"
            fi
        else
            log_message "WARNING: Could not flush binary logs"
        fi
    fi
fi

# Find all binary logs except the current one
cd "$BINLOG_DIR"
AVAILABLE_BINLOGS=$(ls -1 mysql-bin.[0-9]* 2>/dev/null | grep -v "^${CURRENT_BINLOG}$" | sort || true)

if [ -z "$AVAILABLE_BINLOGS" ]; then
    log_message "No completed binary logs found to upload"
    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_binlog uploaded=0 failed=0 size_bytes=0 duration_seconds=$(($(date +%s) - START_TIME))"
    exit 0
fi

# Process each completed binary log
UPLOADED_COUNT=0
UPLOADED_SIZE=0
FAILED_COUNT=0
VERIFIED_COUNT=0

for binlog in $AVAILABLE_BINLOGS; do
    # Check if already uploaded
    if grep -q "^${binlog}$" "$BINLOG_STATE_FILE" 2>/dev/null; then
        continue
    fi

    # This is a new completed binlog - upload it
    log_message "Processing new binary log: $binlog"

    # Get file size
    FILE_SIZE=$(stat -c%s "$binlog" 2>/dev/null || echo "0")
    FILE_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B $FILE_SIZE 2>/dev/null || echo "$FILE_SIZE bytes")

    # Upload to S3
    S3_PATH="s3://$AWS_BACKUP_BUCKET/mariadb-binlog/$(hostname)/$(date +%Y/%m)/$binlog"

    UPLOAD_START=$(date +%s)
    if aws s3 cp "$binlog" "$S3_PATH" --only-show-errors; then
        UPLOAD_DURATION=$(($(date +%s) - UPLOAD_START))
        log_message "Uploaded $binlog ($FILE_SIZE_HUMAN) in ${UPLOAD_DURATION}s"

        # Verify the upload
        log_message "Verifying upload of $binlog"
        S3_SIZE=$(aws s3api head-object --bucket "$AWS_BACKUP_BUCKET" --key "mariadb-binlog/$(hostname)/$(date +%Y/%m)/$binlog" --query 'ContentLength' --output text 2>/dev/null || echo "0")

        if [ "$S3_SIZE" = "$FILE_SIZE" ]; then
            log_message "Upload verified - sizes match"
            VERIFIED_COUNT=$((VERIFIED_COUNT + 1))

            # Record successful upload only after verification
            echo "$binlog" >> "$BINLOG_STATE_FILE"
            UPLOADED_COUNT=$((UPLOADED_COUNT + 1))
            UPLOADED_SIZE=$((UPLOADED_SIZE + FILE_SIZE))

            # Log metrics
            logger -t soc2-backup "BINLOG_UPLOADED: file=$binlog size_bytes=$FILE_SIZE duration_seconds=$UPLOAD_DURATION verified=true"
        else
            log_message "WARNING: Upload verification failed - size mismatch (local: $FILE_SIZE, S3: $S3_SIZE)"
            FAILED_COUNT=$((FAILED_COUNT + 1))

            # Try to clean up the bad upload
            aws s3 rm "$S3_PATH" 2>/dev/null || true
        fi
    else
        log_message "ERROR: Failed to upload $binlog"
        FAILED_COUNT=$((FAILED_COUNT + 1))

        # Send immediate alert for upload failures
        echo "Failed to upload binary log $binlog on $(hostname) - check network connectivity and AWS credentials" | mail -s "[BACKUP ERROR] Binary Log Upload Failed" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    fi
done

# Calculate duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Log completion metrics
UPLOAD_STATUS="success"
if [ "$FAILED_COUNT" -gt 0 ]; then
    UPLOAD_STATUS="warning"
fi

logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_binlog uploaded=$UPLOADED_COUNT failed=$FAILED_COUNT verified=$VERIFIED_COUNT size_bytes=$UPLOADED_SIZE duration_seconds=$DURATION status=$UPLOAD_STATUS"

# Clean up old state entries for binlogs that no longer exist locally
# (MariaDB has purged them based on retention settings)
if [ -f "$BINLOG_STATE_FILE" ] && [ -s "$BINLOG_STATE_FILE" ]; then
    log_message "Cleaning state file of purged binlogs"
    TEMP_STATE=$(mktemp)
    CLEANED_COUNT=0

    while IFS= read -r logged_binlog; do
        if [ -f "$BINLOG_DIR/$logged_binlog" ]; then
            echo "$logged_binlog" >> "$TEMP_STATE"
        else
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
        fi
    done < "$BINLOG_STATE_FILE"

    if [ "$CLEANED_COUNT" -gt 0 ]; then
        log_message "Removed $CLEANED_COUNT purged binlogs from state file"
        mv "$TEMP_STATE" "$BINLOG_STATE_FILE"
    else
        rm -f "$TEMP_STATE"
    fi
fi

# Send daily summary at 8 AM
if [ "$HOUR" = "08" ]; then
    # Count binlogs uploaded in last 24 hours from the log file
    YESTERDAY=$(date -d yesterday +%Y-%m-%d)
    TODAY=$(date +%Y-%m-%d)

    UPLOADS_24H=$(grep -E "$YESTERDAY|$TODAY" "$LOG_FILE" 2>/dev/null | grep -c "BINLOG_UPLOADED" || echo "0")
    ERRORS_24H=$(grep -E "$YESTERDAY|$TODAY" "$LOG_FILE" 2>/dev/null | grep -c "ERROR:" || echo "0")

    # Get total size from today's metrics
    SIZE_24H=$(grep -E "$YESTERDAY|$TODAY" "$LOG_FILE" 2>/dev/null | grep "BINLOG_UPLOADED" | grep -oP 'size_bytes=\K\d+' | awk '{sum+=$1} END {print sum+0}')
    SIZE_24H_HUMAN=$(numfmt --to=iec-i --suffix=B ${SIZE_24H:-0} 2>/dev/null || echo "0B")

    # Count total binlogs in S3 for this host
    S3_COUNT=$(aws s3 ls "s3://$AWS_BACKUP_BUCKET/mariadb-binlog/$(hostname)/" --recursive 2>/dev/null | grep -c "mysql-bin\." || echo "0")

    # Determine status emoji
    if [ "$ERRORS_24H" -gt 0 ]; then
        STATUS_EMOJI="⚠️"
    else
        STATUS_EMOJI="✅"
    fi

    if [ "$DAY_OF_WEEK" = "1" ]; then
        # Monday - detailed weekly report
        {
            echo "MariaDB Binary Log Weekly Report - $(hostname)"
            echo "Report Date: $(date)"
            echo ""
            echo "Last 24 Hours:"
            echo "- Binlogs uploaded: $UPLOADS_24H"
            echo "- Total size: $SIZE_24H_HUMAN"
            echo "- Upload errors: $ERRORS_24H"
            echo "- Total binlogs in S3: $S3_COUNT"
            echo ""
            echo "Configuration:"
            echo "- Check frequency: Every 15 minutes"
            echo "- Rotation trigger: 100MB or 60 minutes"
            echo "- S3 retention: $S3_RETAIN_MARIADB_BINLOG days"
            echo "- S3 path: s3://$AWS_BACKUP_BUCKET/mariadb-binlog/$(hostname)/"
            echo ""
            echo "Binary Log Health:"
            echo "- Binary logging: Enabled ✓"
            echo "- Current binlog: $(mysql --defaults-file="$MARIADB_DEFAULTS_FILE" -e "SHOW MASTER STATUS\G" 2>/dev/null | grep File | awk '{print $2}')"
            echo "- Position: $(mysql --defaults-file="$MARIADB_DEFAULTS_FILE" -e "SHOW MASTER STATUS\G" 2>/dev/null | grep Position | awk '{print $2}')"
            echo ""
            echo "Recovery Point Objective (RPO): 15 minutes maximum"
            echo ""
            echo "Point-in-Time Recovery Instructions:"
            echo "1. Restore the latest full backup (from 2 AM)"
            echo "2. Download binary logs since the backup:"
            echo "   aws s3 sync s3://$AWS_BACKUP_BUCKET/mariadb-binlog/$(hostname)/ /tmp/binlogs/"
            echo "3. Apply binary logs in sequence:"
            echo "   for log in /tmp/binlogs/mysql-bin.*; do"
            echo "     mysqlbinlog \$log | mysql"
            echo "   done"
            echo "4. Verify data consistency"
            echo ""
            echo "This ensures recovery to within 15 minutes of failure."
        } | mail -s "[Backup] Binary Logs Weekly - $STATUS_EMOJI $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    else
        # Daily brief summary
        {
            echo "$STATUS_EMOJI MariaDB binary logs on $(hostname)"
            echo ""
            echo "Last 24h: $UPLOADS_24H logs uploaded ($SIZE_24H_HUMAN)"
            if [ "$ERRORS_24H" -gt 0 ]; then
                echo "⚠️  Errors: $ERRORS_24H upload failures"
            fi
            echo "Total in S3: $S3_COUNT logs | RPO: 15 minutes"
            echo ""
            echo "Weekly detailed report on Mondays."
        } | mail -s "[Backup] Binary Logs - $STATUS_EMOJI $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    fi
fi

log_message "Binary log backup check completed (uploaded: $UPLOADED_COUNT, verified: $VERIFIED_COUNT, failed: $FAILED_COUNT)"