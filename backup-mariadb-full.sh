#!/bin/bash
set -euo pipefail

# MariaDB full backup with local retention and S3 upload
# Keeps compressed local copies as insurance against upload failures

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/backup.conf

LOG_FILE="/var/log/backups/mariadb-full.log"
DATE_STAMP=$(date +%Y%m%d-%H%M%S)
LOCAL_BACKUP_DIR="/backups/mariadb-local"
LOCAL_RETAIN_DAYS=7  # Keep one week locally

# Structured logging function for monitoring integration
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    logger -t soc2-backup "$1"
}

# Log structured metrics for monitoring
log_metrics() {
    local backup_size=$1
    local status=$2
    local operation_duration=${3:-0}
    local local_copy=$4

    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_full size_bytes=$backup_size status=$status duration_seconds=$operation_duration local_copy=$local_copy"
}

log_message "Starting MariaDB full backup"
BACKUP_START=$(date +%s)

# Create local backup directory if it doesn't exist
mkdir -p "$LOCAL_BACKUP_DIR"

# Check MariaDB is running
if ! systemctl is-active --quiet mariadb; then
    log_message "ERROR: MariaDB service not running"
    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_full status=$STATUS_ERROR error=service_down"
    echo "MariaDB backup failed - service not running on $(hostname)" | mail -s "[BACKUP ERROR] MariaDB Service Down" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1
fi

# Clean up old local backups first to ensure we have space
log_message "Cleaning local backups older than $LOCAL_RETAIN_DAYS days"
find "$LOCAL_BACKUP_DIR" -name "mariadb-*.bz2" -mtime +$LOCAL_RETAIN_DAYS -delete 2>/dev/null || true

# Define paths
LOCAL_PATH="$LOCAL_BACKUP_DIR/mariadb-$DATE_STAMP.mbstream"
COMPRESSED_PATH="${LOCAL_PATH}.bz2"
S3_PATH="s3://$AWS_BACKUP_BUCKET/mariadb-full/$(hostname)/$(date +%Y/%m)/backup-$DATE_STAMP.mbstream.bz2"

log_message "Starting MariaDB backup to local disk"

# Stream backup to local file first
if mariadb-backup --backup \
    --defaults-file=/root/.backup.cnf \
    --stream=mbstream \
    --compress \
    --compress-threads=2 > "$LOCAL_PATH" 2>/dev/null; then

    BACKUP_STREAM_STATUS="success"
    log_message "Backup stream completed successfully"

    # Get uncompressed size for reporting
    UNCOMPRESSED_SIZE=$(stat -c%s "$LOCAL_PATH" 2>/dev/null || echo "0")
    log_message "Uncompressed backup size: $(numfmt --to=iec-i --suffix=B $UNCOMPRESSED_SIZE)"

else
    BACKUP_STREAM_STATUS="failed"
    log_message "ERROR: Backup stream failed"
    rm -f "$LOCAL_PATH"
fi

# Compress the backup locally
LOCAL_RESULT="failed"
S3_RESULT="failed"

if [ "$BACKUP_STREAM_STATUS" = "success" ]; then
    log_message "Compressing backup with pbzip2"

    # Use nice and ionice to minimize production impact
    if nice -n 19 ionice -c2 -n7 pbzip2 -k "$LOCAL_PATH"; then
        LOCAL_RESULT="success"
        log_message "Compression completed successfully"

        # Remove uncompressed file to save space
        rm -f "$LOCAL_PATH"

        # Upload to S3
        log_message "Uploading compressed backup to S3"
        if aws s3 cp "$COMPRESSED_PATH" "$S3_PATH"; then
            S3_RESULT="success"
            log_message "S3 upload completed successfully"
        else
            S3_RESULT="failed"
            log_message "WARNING: S3 upload failed - local backup retained"
        fi
    else
        LOCAL_RESULT="failed"
        log_message "ERROR: Compression failed"
        rm -f "$LOCAL_PATH"
    fi
fi

# Determine overall status
if [ "$BACKUP_STREAM_STATUS" = "failed" ]; then
    BACKUP_STATUS="$STATUS_ERROR"
    LOCAL_COPY="failed"

    logger -t soc2-security "BACKUP_FAILURE: service=mariadb severity=critical"
    echo "MariaDB full backup failed on $(hostname)" | \
        mail -s "[BACKUP CRITICAL] MariaDB Full Backup Failed - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1

elif [ "$S3_RESULT" = "failed" ] && [ "$LOCAL_RESULT" = "failed" ]; then
    BACKUP_STATUS="$STATUS_ERROR"
    LOCAL_COPY="failed"

    logger -t soc2-security "BACKUP_FAILURE: service=mariadb severity=critical storage=both_failed"
    echo "MariaDB backup failed - both S3 and local storage failed on $(hostname)" | \
        mail -s "[BACKUP CRITICAL] Complete Storage Failure - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1

elif [ "$S3_RESULT" = "failed" ]; then
    BACKUP_STATUS="$STATUS_WARNING"
    LOCAL_COPY="success"

    log_message "WARNING: S3 upload failed but local backup succeeded"
    logger -t soc2-security "BACKUP_WARNING: service=mariadb severity=high issue=s3_upload_failed local_backup=available"

else
    BACKUP_STATUS="$STATUS_SUCCESS"
    LOCAL_COPY="success"
    log_message "Backup completed successfully to both destinations"
fi

BACKUP_END=$(date +%s)
BACKUP_DURATION=$((BACKUP_END - BACKUP_START))

# Get backup sizes
if [ -f "$COMPRESSED_PATH" ]; then
    LOCAL_SIZE=$(stat -c%s "$COMPRESSED_PATH" 2>/dev/null || echo "0")
    LOCAL_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B $LOCAL_SIZE 2>/dev/null || echo "$LOCAL_SIZE bytes")
else
    LOCAL_SIZE=0
    LOCAL_SIZE_HUMAN="N/A"
fi

# Use local size for metrics since S3 upload might have failed
BACKUP_SIZE=$LOCAL_SIZE

# Log structured metrics
log_metrics "$BACKUP_SIZE" "$BACKUP_STATUS" "$BACKUP_DURATION" "$LOCAL_COPY"

# Count local backups for reporting
LOCAL_BACKUP_COUNT=$(find "$LOCAL_BACKUP_DIR" -name "mariadb-*.bz2" 2>/dev/null | wc -l)
LOCAL_BACKUP_TOTAL=$(du -sh "$LOCAL_BACKUP_DIR" 2>/dev/null | cut -f1 || echo "Unknown")

# Send notification with enhanced status information
{
    echo "MariaDB full backup completed on $(hostname)"
    echo ""
    echo "Backup Summary:"
    echo "- Timestamp: $DATE_STAMP"
    echo "- Duration: ${BACKUP_DURATION} seconds"
    echo "- Status: $BACKUP_STATUS"
    echo ""
    echo "Storage Destinations:"
    if [ "$S3_RESULT" = "success" ]; then
        echo "✓ S3 Upload: Success"
        echo "  Location: $S3_PATH"
        echo "  Size: $LOCAL_SIZE_HUMAN"
    else
        echo "✗ S3 Upload: FAILED"
        echo "  Check network connectivity and AWS credentials"
    fi
    echo ""
    if [ "$LOCAL_RESULT" = "success" ]; then
        echo "✓ Local Backup: Success"
        echo "  Location: $COMPRESSED_PATH"
        echo "  Size: $LOCAL_SIZE_HUMAN"
        echo "  Compression: pbzip2 (parallel)"
    else
        echo "✗ Local Backup: FAILED"
        echo "  Check disk space in $LOCAL_BACKUP_DIR"
    fi
    echo ""
    echo "Local Backup Inventory:"
    echo "- Files stored: $LOCAL_BACKUP_COUNT"
    echo "- Total size: $LOCAL_BACKUP_TOTAL"
    echo "- Retention: $LOCAL_RETAIN_DAYS days"
    echo ""
    echo "Recovery Instructions:"
    if [ "$LOCAL_RESULT" = "success" ]; then
        echo "From local backup (fastest):"
        echo "1. Decompress: pbzip2 -d -k $COMPRESSED_PATH"
        echo "2. Extract: mbstream -x < ${COMPRESSED_PATH%.bz2}"
        echo "3. Prepare: mariadb-backup --prepare --target-dir=."
        echo "4. Restore: mariadb-backup --copy-back --target-dir=."
    fi
    if [ "$S3_RESULT" = "success" ]; then
        echo ""
        echo "From S3 backup:"
        echo "1. Download: aws s3 cp $S3_PATH backup.mbstream.bz2"
        echo "2. Decompress: pbzip2 -d backup.mbstream.bz2"
        echo "3. Extract: mbstream -x < backup.mbstream"
        echo "4. Prepare: mariadb-backup --prepare --target-dir=."
        echo "5. Restore: mariadb-backup --copy-back --target-dir=."
    fi

    if [ "$S3_RESULT" = "failed" ] && [ "$LOCAL_RESULT" = "success" ]; then
        echo ""
        echo "⚠️  ACTION REQUIRED: S3 upload failed but local backup is available."
        echo "Please investigate S3 connectivity to ensure off-site backups resume."
    fi

} | mail -s "[Backup] MariaDB Full - $BACKUP_STATUS - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"

log_message "MariaDB full backup completed"