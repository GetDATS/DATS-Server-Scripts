#!/bin/bash
set -euo pipefail

# Backup cleanup - removes expired backups from S3 based on retention policies
# Keeps storage costs under control while maintaining compliance requirements

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/backup.conf

LOG_FILE="/var/log/backups/cleanup.log"

# Structured logging function for monitoring integration
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    logger -t soc2-backup "$1"
}

# Log structured metrics for monitoring
log_metrics() {
    local files_deleted=$1
    local bytes_freed=$2
    local status=$3
    local operation_duration=${4:-0}

    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=cleanup files_deleted=$files_deleted bytes_freed=$bytes_freed status=$status duration_seconds=$operation_duration"
}

log_message "Starting backup cleanup"
CLEANUP_START=$(date +%s)

# Initialize counters
TOTAL_DELETED=0
TOTAL_BYTES=0

# Function to clean old backups
cleanup_backups() {
    local prefix=$1
    local retention_days=$2
    local backup_type=$3
    
    log_message "Cleaning $backup_type backups older than $retention_days days"
    
    local cutoff_date=$(date -d "$retention_days days ago" +%Y-%m-%d)
    local deleted_count=0
    local deleted_bytes=0
    
    # List all objects with the prefix
    aws s3api list-objects-v2 \
        --bucket "$AWS_BACKUP_BUCKET" \
        --prefix "$prefix" \
        --query "Contents[?LastModified<='${cutoff_date}T00:00:00.000Z'].[Key,Size]" \
        --output text | while read -r key size; do
        
        if [ -n "$key" ] && [ "$key" != "None" ]; then
            # Delete the object
            if aws s3 rm "s3://$AWS_BACKUP_BUCKET/$key"; then
                deleted_count=$((deleted_count + 1))
                deleted_bytes=$((deleted_bytes + size))
                log_message "Deleted: $key ($(numfmt --to=iec-i --suffix=B $size))"
            else
                log_message "ERROR: Failed to delete $key"
            fi
        fi
    done
    
    # Update global counters
    TOTAL_DELETED=$((TOTAL_DELETED + deleted_count))
    TOTAL_BYTES=$((TOTAL_BYTES + deleted_bytes))
    
    if [ "$deleted_count" -gt 0 ]; then
        log_message "Cleaned $deleted_count $backup_type backups, freed $(numfmt --to=iec-i --suffix=B $deleted_bytes)"
    else
        log_message "No expired $backup_type backups found"
    fi
}

# Clean each backup type based on retention policy for this server
HOSTNAME=$(hostname)
cleanup_backups "mariadb-full/$HOSTNAME/" "$RETAIN_MARIADB_FULL" "MariaDB full"
cleanup_backups "mariadb-binlog/$HOSTNAME/" "$RETAIN_MARIADB_BINLOG" "MariaDB binlog"
cleanup_backups "home/$HOSTNAME/" "$RETAIN_HOME_ARCHIVE" "home directory"
cleanup_backups "logs/$HOSTNAME/" "$RETAIN_LOG_ARCHIVE" "log archive"

CLEANUP_END=$(date +%s)
CLEANUP_DURATION=$((CLEANUP_END - CLEANUP_START))

# Determine cleanup status
if [ "$TOTAL_DELETED" -gt 0 ]; then
    CLEANUP_STATUS="$STATUS_SUCCESS"
    
    # Get current bucket size for reporting
    BUCKET_SIZE=$(aws s3api list-objects-v2 \
        --bucket "$AWS_BACKUP_BUCKET" \
        --query "sum(Contents[].Size)" \
        --output text 2>/dev/null || echo "0")
    
    # Send cleanup report
    {
        echo "Backup cleanup completed on $(hostname)"
        echo ""
        echo "Cleanup Summary:"
        echo "- Files deleted: $TOTAL_DELETED"
        echo "- Space freed: $(numfmt --to=iec-i --suffix=B $TOTAL_BYTES)"
        echo "- Duration: ${CLEANUP_DURATION} seconds"
        echo ""
        echo "Retention Policy Applied:"
        echo "- MariaDB full backups: $RETAIN_MARIADB_FULL days"
        echo "- MariaDB binary logs: $RETAIN_MARIADB_BINLOG days"
        echo "- Home directories: $RETAIN_HOME_ARCHIVE days"
        echo "- Log archives: $RETAIN_LOG_ARCHIVE days"
        echo ""
        echo "Current bucket size: $(numfmt --to=iec-i --suffix=B ${BUCKET_SIZE:-0})"
        echo ""
        echo "This cleanup ensures compliance with retention policies"
        echo "while managing storage costs effectively."
    } | mail -s "[Backup] Cleanup - $TOTAL_DELETED files removed - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    
else
    CLEANUP_STATUS="$STATUS_SUCCESS"  # No files to delete is still success
    log_message "No expired backups found"
    
    # Weekly report even when nothing deleted
    {
        echo "Backup cleanup check completed on $(hostname)"
        echo ""
        echo "No expired backups found - all backups within retention period."
        echo ""
        echo "Current Retention Policy:"
        echo "- MariaDB full backups: $RETAIN_MARIADB_FULL days"
        echo "- MariaDB binary logs: $RETAIN_MARIADB_BINLOG days"  
        echo "- Home directories: $RETAIN_HOME_ARCHIVE days"
        echo "- Log archives: $RETAIN_LOG_ARCHIVE days"
        echo ""
        echo "Next cleanup check: 1 week"
    } | mail -s "[Backup] Cleanup - No action needed - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
fi

# Log structured metrics
log_metrics "$TOTAL_DELETED" "$TOTAL_BYTES" "$CLEANUP_STATUS" "$CLEANUP_DURATION"

log_message "Backup cleanup completed"