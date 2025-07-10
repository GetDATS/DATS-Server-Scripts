#!/bin/bash
set -euo pipefail

# Log archive backup - ships rotated logs to S3 for compliance
# Archives yesterday's logs for 365-day retention requirement

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/backup.conf

LOG_FILE="/var/log/backups/log-archive.log"
DATE_STAMP=$(date +%Y%m%d)
TEMP_DIR=$(mktemp -d)

# Structured logging function for monitoring integration
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    logger -t soc2-backup "$1"
}

# Log structured metrics for monitoring
log_metrics() {
    local archive_size=$1
    local files_count=$2
    local status=$3
    local operation_duration=${4:-0}

    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=log_archive size_bytes=$archive_size files_count=$files_count status=$status duration_seconds=$operation_duration"
}

# Cleanup on exit
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

log_message "Starting log archive backup"
BACKUP_START=$(date +%s)

# Define what logs to archive (rotated logs from yesterday)
LOG_PATTERNS=(
    "*.log.1"
    "*.1"
    "*.gz"
    "*-$(date -d yesterday +%Y%m%d)*"
)

# Directories to exclude from archiving
EXCLUDE_DIRS=(
    "/var/log/journal"
    "/var/log/private"
    "/var/log/backups"  # Don't backup backup logs
)

# Build find command with patterns
FIND_CMD="find /var/log -type f \\( "
FIRST=true
for pattern in "${LOG_PATTERNS[@]}"; do
    if [ "$FIRST" = true ]; then
        FIND_CMD="$FIND_CMD -name \"$pattern\""
        FIRST=false
    else
        FIND_CMD="$FIND_CMD -o -name \"$pattern\""
    fi
done
FIND_CMD="$FIND_CMD \\)"

# Add exclude directories
for exclude_dir in "${EXCLUDE_DIRS[@]}"; do
    FIND_CMD="$FIND_CMD -not -path \"$exclude_dir/*\""
done

# Add time constraint - only yesterday's files
FIND_CMD="$FIND_CMD -mtime 1"

log_message "Collecting rotated logs for archival"

# Create archive
ARCHIVE_PATH="$TEMP_DIR/logs-$DATE_STAMP.tar.gz"

# Find and archive the logs
FILES_LIST=$(eval "$FIND_CMD" 2>/dev/null | sort || true)
FILE_COUNT=$(echo "$FILES_LIST" | grep -v "^$" | wc -l || echo "0")

if [ "$FILE_COUNT" -gt 0 ]; then
    log_message "Found $FILE_COUNT log files to archive"
    
    # Create the archive
    echo "$FILES_LIST" | tar czf "$ARCHIVE_PATH" -T - 2>/dev/null
    
    ARCHIVE_SIZE=$(stat -c%s "$ARCHIVE_PATH" 2>/dev/null || echo "0")
    log_message "Archive created: $(numfmt --to=iec-i --suffix=B $ARCHIVE_SIZE)"
    
    # Upload to S3 with backup-type-first organization - straight to Glacier IR
    S3_PATH="s3://$AWS_BACKUP_BUCKET/logs/$(hostname)/$(date +%Y/%m)/logs-$DATE_STAMP.tar.gz"
    
    log_message "Uploading to: $S3_PATH"
    
    if aws s3 cp "$ARCHIVE_PATH" "$S3_PATH" --storage-class GLACIER_IR; then
        UPLOAD_STATUS="$STATUS_SUCCESS"
        log_message "Upload completed successfully"
    else
        UPLOAD_STATUS="$STATUS_ERROR"
        log_message "ERROR: Upload to S3 failed"
        logger -t soc2-security "BACKUP_FAILURE: service=log-archive severity=medium"
        
        echo "Log archive upload failed on $(hostname)" | \
            mail -s "[BACKUP ERROR] Log Archive Upload Failed - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
        exit 1
    fi
else
    UPLOAD_STATUS="$STATUS_SUCCESS"  # No logs to archive is still success
    ARCHIVE_SIZE=0
    log_message "No rotated logs found to archive"
fi

BACKUP_END=$(date +%s)
BACKUP_DURATION=$((BACKUP_END - BACKUP_START))

# Log structured metrics
log_metrics "$ARCHIVE_SIZE" "$FILE_COUNT" "$UPLOAD_STATUS" "$BACKUP_DURATION"

# Send notification for successful archives
if [ "$FILE_COUNT" -gt 0 ]; then
    # Categorize archive size for reporting
    if [ "$ARCHIVE_SIZE" -gt 104857600 ]; then  # > 100MB
        SIZE_CATEGORY="large"
    elif [ "$ARCHIVE_SIZE" -gt 10485760 ]; then  # > 10MB
        SIZE_CATEGORY="medium"
    else
        SIZE_CATEGORY="small"
    fi
    
    {
        echo "Log archive backup completed successfully on $(hostname)"
        echo ""
        echo "Archive Details:"
        echo "- Date: $DATE_STAMP"
        echo "- Files archived: $FILE_COUNT"
        echo "- Size: $(numfmt --to=iec-i --suffix=B $ARCHIVE_SIZE) ($SIZE_CATEGORY archive)"
        echo "- Duration: ${BACKUP_DURATION} seconds"
        echo "- Location: $S3_PATH"
        echo ""
        echo "Storage class: GLACIER_IR (immediate archival)"
        echo "Retention: $RETAIN_LOG_ARCHIVE days (SOC 2 requirement)"
        echo ""
        echo "These logs include:"
        echo "- System logs"
        echo "- Security logs"
        echo "- Application logs"
        echo "- Audit logs"
        echo ""
        echo "Recovery: aws s3 cp $S3_PATH - | tar xzf - -C /"
    } | mail -s "[Backup] Log Archive - Success - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
else
    # Weekly summary even when no logs
    if [ "$(date +%u)" = "7" ]; then  # Sunday
        {
            echo "Weekly log archive summary for $(hostname)"
            echo ""
            echo "No rotated logs found for today's archive."
            echo ""
            echo "This can happen when:"
            echo "- Log rotation hasn't occurred yet"
            echo "- All logs are still active"
            echo "- Previous archives already captured the logs"
            echo ""
            echo "Current log retention policy: $RETAIN_LOG_ARCHIVE days"
        } | mail -s "[Backup] Log Archive - Weekly Summary - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    fi
fi

log_message "Log archive backup completed"