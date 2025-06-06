#!/bin/bash
set -euo pipefail

# BorgBackup script for filesystem data with local retention and AWS staging
# Runs every 6 hours, keeps 7 days local, stages for AWS upload

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/borg-backup.conf

LOG_FILE="/var/log/backups/borg-backup.log"
DATE_STAMP=$(date +%Y%m%d-%H%M%S)
STAGING_DIR="$BACKUP_BASE/aws-staging/borg"

# Export borg environment variables
export BORG_REPO
export BORG_PASSPHRASE

# Datadog-friendly logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    logger -t borg-backup "$1"
}

# Create staging directory if it doesn't exist
mkdir -p "$STAGING_DIR"

log_message "Starting Borg backup - $DATE_STAMP"

# Define what to backup
BACKUP_PATHS=(
    "/etc"
    "/home"
    "/var/www"
    "/var/php/uploads"
    "/var/lib/aide/aide.db"
    "/usr/local/share/soc2-scripts"
)

# Define what to exclude
BACKUP_EXCLUDES=(
    "*.tmp"
    "*.log"
    "*/.cache"
    "*/lost+found"
    "/var/php/sessions"
    "/etc/ssl/private"
)

# Build exclude parameters
EXCLUDE_PARAMS=""
for exclude in "${BACKUP_EXCLUDES[@]}"; do
    EXCLUDE_PARAMS="$EXCLUDE_PARAMS --exclude $exclude"
done

BACKUP_START=$(date +%s)

log_message "Creating Borg archive: $DATE_STAMP"

# Create the backup
if borg create \
    --verbose \
    --stats \
    --compression lz4 \
    $EXCLUDE_PARAMS \
    "::filesystem-$DATE_STAMP" \
    "${BACKUP_PATHS[@]}" 2>&1 | tee -a "$LOG_FILE"; then

    BACKUP_STATUS="success"
    log_message "Borg backup completed successfully"
else
    BACKUP_STATUS="failed"
    log_message "ERROR: Borg backup failed"
    echo "Borg backup failed on $(hostname) at $(date)" | mail -s "[BACKUP ERROR] Borg Backup Failed" "$ADMIN_EMAIL"
    exit 1
fi

BACKUP_END=$(date +%s)
BACKUP_DURATION=$((BACKUP_END - BACKUP_START))

# Get backup statistics
BACKUP_STATS=$(borg info "::filesystem-$DATE_STAMP" 2>/dev/null | grep -E "(Original size|Compressed size|Deduplicated size)" || echo "Stats unavailable")

# Log structured metrics for Datadog
logger -t borg-backup "BACKUP_COMPLETE: status=$BACKUP_STATUS duration=${BACKUP_DURATION}s archive=filesystem-$DATE_STAMP"

# Prune old backups (keep 7 days worth)
log_message "Pruning old archives"

if borg prune \
    --keep-within=7d \
    --list 2>&1 | tee -a "$LOG_FILE"; then

    log_message "Pruning completed successfully"
else
    log_message "WARNING: Pruning encountered issues"
fi

# Stage weekly backups for AWS upload (only on Sundays at midnight)
DAY_OF_WEEK=$(date +%u)
CURRENT_HOUR=$(date +%H)
if [ "$DAY_OF_WEEK" = "7" ] && [ "$CURRENT_HOUR" = "00" ]; then
    log_message "Staging weekly backup for AWS upload"

    # Export the latest archive for AWS
    ARCHIVE_NAME="borg-weekly-$(date +%Y%m%d).tar"
    ARCHIVE_PATH="$STAGING_DIR/$ARCHIVE_NAME"

    if borg export-tar "::filesystem-$DATE_STAMP" "$ARCHIVE_PATH" 2>&1 | tee -a "$LOG_FILE"; then
        # Compress the archive
        gzip "$ARCHIVE_PATH"
        log_message "AWS staging completed: ${ARCHIVE_PATH}.gz"
        logger -t borg-backup "AWS_STAGED: archive=${ARCHIVE_NAME}.gz size=$(du -sh "${ARCHIVE_PATH}.gz" | cut -f1)"
    else
        log_message "ERROR: AWS staging failed"
        echo "Borg AWS staging failed on $(hostname)" | mail -s "[BACKUP ERROR] Borg AWS Staging Failed" "$ADMIN_EMAIL"
    fi
fi

# Get repository info for monitoring
REPO_INFO=$(borg info "$BORG_REPO" 2>/dev/null | grep -E "(Number of archives|Repository size)" || echo "Repository info unavailable")
ARCHIVE_COUNT=$(borg list --short 2>/dev/null | wc -l)

log_message "Local retention: $ARCHIVE_COUNT archives stored"

# Send success notification
{
    echo "Borg filesystem backup completed successfully on $(hostname)"
    echo ""
    echo "Backup Details:"
    echo "- Archive: filesystem-$DATE_STAMP"
    echo "- Duration: ${BACKUP_DURATION} seconds"
    echo "- Archives stored: $ARCHIVE_COUNT"
    echo ""
    echo "Backup Statistics:"
    echo "$BACKUP_STATS"
    echo ""
    echo "Repository Information:"
    echo "$REPO_INFO"
    echo ""
    echo "View backup metrics in your Datadog dashboard."
} | mail -s "[Backup] Borg Backup - Success - $(hostname)" "$ADMIN_EMAIL"

log_message "Borg backup completed successfully"