#!/bin/bash
set -euo pipefail

# MariaDB full backup using mariadb-backup with direct S3 streaming
# Hot backups without table locks, maintaining full availability

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/backup.conf

LOG_FILE="/var/log/backups/mariadb-full.log"
DATE_STAMP=$(date +%Y%m%d-%H%M%S)

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

    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_full size_bytes=$backup_size status=$status duration_seconds=$operation_duration"
}

log_message "Starting MariaDB full backup"
BACKUP_START=$(date +%s)

# Check MariaDB is running
if ! systemctl is-active --quiet mariadb; then
    log_message "ERROR: MariaDB service not running"
    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_full status=$STATUS_ERROR error=service_down"
    echo "MariaDB backup failed - service not running on $(hostname)" | mail -s "[BACKUP ERROR] MariaDB Service Down" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1
fi

# Define S3 path with backup-type-first organization
S3_PATH="s3://$AWS_BACKUP_BUCKET/mariadb-full/$(hostname)/$(date +%Y/%m)/backup-$DATE_STAMP.mbstream"

# Stream backup directly to S3 using mariadb-backup
# This creates a hot backup without locking tables
log_message "Streaming backup to: $S3_PATH"

if mariadb-backup --backup \
    --user="$MARIADB_BACKUP_USER" \
    --password="$MARIADB_ADMIN_PASSWORD" \
    --stream=mbstream \
    --compress \
    --compress-threads=2 2>/dev/null | \
    aws s3 cp - "$S3_PATH" --expected-size 1073741824; then
    
    BACKUP_STATUS="$STATUS_SUCCESS"
    log_message "Backup stream completed successfully"
    
    # Get backup size from S3
    BACKUP_SIZE=$(aws s3api head-object --bucket "$AWS_BACKUP_BUCKET" --key "${S3_PATH#s3://$AWS_BACKUP_BUCKET/}" --query ContentLength --output text 2>/dev/null || echo "0")
    
else
    BACKUP_STATUS="$STATUS_ERROR"
    BACKUP_SIZE=0
    log_message "ERROR: Backup stream failed"
    logger -t soc2-security "BACKUP_FAILURE: service=mariadb severity=critical"
    
    echo "MariaDB full backup failed on $(hostname)" | \
        mail -s "[BACKUP CRITICAL] MariaDB Full Backup Failed - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1
fi

BACKUP_END=$(date +%s)
BACKUP_DURATION=$((BACKUP_END - BACKUP_START))

# Log structured metrics
log_metrics "$BACKUP_SIZE" "$BACKUP_STATUS" "$BACKUP_DURATION"

# Send success notification
{
    echo "MariaDB full backup completed successfully on $(hostname)"
    echo ""
    echo "Backup Details:"
    echo "- Timestamp: $DATE_STAMP"
    echo "- Duration: ${BACKUP_DURATION} seconds"
    echo "- Size: $(numfmt --to=iec-i --suffix=B ${BACKUP_SIZE} 2>/dev/null || echo "${BACKUP_SIZE} bytes")"
    echo "- Type: Hot backup (no table locks)"
    echo "- Location: $S3_PATH"
    echo ""
    echo "Retention: $RETAIN_MARIADB_FULL days"
    echo ""
    echo "Recovery Instructions:"
    echo "1. Download: aws s3 cp $S3_PATH backup.mbstream"
    echo "2. Extract: mbstream -x < backup.mbstream"
    echo "3. Prepare: mariadb-backup --prepare --target-dir=."
    echo "4. Restore: mariadb-backup --copy-back --target-dir=."
    echo ""
    echo "View backup metrics in your Datadog dashboard."
} | mail -s "[Backup] MariaDB Full - Success - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"

log_message "MariaDB full backup completed"