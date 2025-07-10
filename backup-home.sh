#!/bin/bash
set -euo pipefail

# Home directory backup - archives user data and configurations
# Captures the human element: scripts, configs, and work in progress

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/backup.conf

LOG_FILE="/var/log/backups/home-backup.log"
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

    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=home_archive size_bytes=$archive_size files_count=$files_count status=$status duration_seconds=$operation_duration"
}

# Cleanup on exit
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

log_message "Starting home directory backup"
BACKUP_START=$(date +%s)

# Create archive locally first (for integrity and metrics)
ARCHIVE_PATH="$TEMP_DIR/home-$DATE_STAMP.tar.gz"

# Build exclude patterns for tar
EXCLUDES=(
    "--exclude=.cache"
    "--exclude=.npm"
    "--exclude=.composer"
    "--exclude=.local/share/Trash"
    "--exclude=.thumbnails"
    "--exclude=*.log"
    "--exclude=*.tmp"
)

log_message "Creating home directory archive"

# Create the archive
if tar czf "$ARCHIVE_PATH" "${EXCLUDES[@]}" /home 2>/dev/null; then
    ARCHIVE_STATUS="success"
    
    # Get archive metrics
    ARCHIVE_SIZE=$(stat -c%s "$ARCHIVE_PATH" 2>/dev/null || echo "0")
    FILES_COUNT=$(tar -tzf "$ARCHIVE_PATH" 2>/dev/null | wc -l || echo "0")
    
    log_message "Archive created: $(numfmt --to=iec-i --suffix=B $ARCHIVE_SIZE), $FILES_COUNT files"
else
    ARCHIVE_STATUS="failed"
    log_message "ERROR: Failed to create archive"
    logger -t soc2-security "BACKUP_FAILURE: service=home-backup severity=medium"
    
    BACKUP_END=$(date +%s)
    BACKUP_DURATION=$((BACKUP_END - BACKUP_START))
    log_metrics "0" "0" "$STATUS_ERROR" "$BACKUP_DURATION"
    
    echo "Home directory backup failed on $(hostname)" | \
        mail -s "[BACKUP ERROR] Home Directory Backup Failed - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1
fi

# Upload to S3 with backup-type-first organization
S3_PATH="s3://$AWS_BACKUP_BUCKET/home/$(hostname)/$(date +%Y/%m)/home-$DATE_STAMP.tar.gz"

log_message "Uploading to: $S3_PATH"

if aws s3 cp "$ARCHIVE_PATH" "$S3_PATH"; then
    UPLOAD_STATUS="$STATUS_SUCCESS"
    log_message "Upload completed successfully"
else
    UPLOAD_STATUS="$STATUS_ERROR"
    log_message "ERROR: Upload to S3 failed"
    logger -t soc2-security "BACKUP_FAILURE: service=home-backup severity=medium"
    
    BACKUP_END=$(date +%s)
    BACKUP_DURATION=$((BACKUP_END - BACKUP_START))
    log_metrics "$ARCHIVE_SIZE" "$FILES_COUNT" "$STATUS_ERROR" "$BACKUP_DURATION"
    
    echo "Home directory upload failed on $(hostname)" | \
        mail -s "[BACKUP ERROR] Home Directory Upload Failed - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1
fi

BACKUP_END=$(date +%s)
BACKUP_DURATION=$((BACKUP_END - BACKUP_START))

# Log structured metrics
log_metrics "$ARCHIVE_SIZE" "$FILES_COUNT" "$UPLOAD_STATUS" "$BACKUP_DURATION"

# Categorize backup size for reporting
if [ "$ARCHIVE_SIZE" -gt 1073741824 ]; then  # > 1GB
    SIZE_CATEGORY="large"
elif [ "$ARCHIVE_SIZE" -gt 104857600 ]; then  # > 100MB
    SIZE_CATEGORY="medium"
else
    SIZE_CATEGORY="small"
fi

# Send success notification
{
    echo "Home directory backup completed successfully on $(hostname)"
    echo ""
    echo "Backup Details:"
    echo "- Date: $DATE_STAMP"
    echo "- Size: $(numfmt --to=iec-i --suffix=B $ARCHIVE_SIZE) ($SIZE_CATEGORY backup)"
    echo "- Files: $FILES_COUNT"
    echo "- Duration: ${BACKUP_DURATION} seconds"
    echo "- Location: $S3_PATH"
    echo ""
    echo "Content includes:"
    echo "- User home directories"
    echo "- Personal configurations"
    echo "- Scripts and work files"
    echo ""
    echo "Retention: $RETAIN_HOME_ARCHIVE days"
    echo ""
    echo "Recovery: aws s3 cp $S3_PATH - | tar xzf - -C /"
} | mail -s "[Backup] Home Directory - Success - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"

log_message "Home directory backup completed"