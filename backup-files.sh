#!/bin/bash
set -euo pipefail

# File Backup - Sync only business-critical directories to S3
# Everything else is in GitHub or regeneratable

# Load configuration
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/backup.conf

LOG_FILE="$FILE_BACKUP_LOG"
HOUR=$(date +%H)

# Simple logging
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    logger -t soc2-file-backup "$1"
}

# Use flock for clean locking
exec 200>/var/run/backup-files.lock
if ! flock -n 200; then
    exit 0
fi

log_message "Starting file backup"
BACKUP_START=$(date +%s)

# Preflight checks
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_message "ERROR: AWS credentials not configured"
    echo "AWS credentials invalid on $(hostname)" | mail -s "[BACKUP ERROR] File Backup Failed" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1
fi

# Track totals
TOTAL_FILES_SYNCED=0
TOTAL_PATHS_SYNCED=0
FAILED_PATHS=()

# Sync each file path from configuration
for FILE_PATH in "${FILE_BACKUP_PATHS[@]}"; do
    # Skip if path doesn't exist
    if [ ! -d "$FILE_PATH" ]; then
        log_message "WARNING: Path does not exist: $FILE_PATH"
        continue
    fi

    # Create S3 path that preserves structure
    S3_PATH="s3://$AWS_BACKUP_BUCKET/files/$(hostname)${FILE_PATH}/"

    log_message "Syncing: $FILE_PATH"

    # Capture sync output
    SYNC_OUTPUT=$(mktemp)

    SYNC_SUCCESS=false

    if aws s3 sync "$FILE_PATH" "$S3_PATH" 2>&1 | tee "$SYNC_OUTPUT"; then
        SYNC_SUCCESS=true
    else
        # Retry once after 30 seconds - handles transient file-change races
        log_message "WARNING: First sync attempt failed for $FILE_PATH, retrying in 30s"
        sleep 30
        rm -f "$SYNC_OUTPUT"
        SYNC_OUTPUT=$(mktemp)
        if aws s3 sync "$FILE_PATH" "$S3_PATH" 2>&1 | tee "$SYNC_OUTPUT"; then
            SYNC_SUCCESS=true
            log_message "  Retry succeeded"
        else
            log_message "ERROR: Failed to sync $FILE_PATH after retry"
            FAILED_PATHS+=("$FILE_PATH")
        fi
    fi

    if [ "$SYNC_SUCCESS" = true ]; then
        # Count what was synced
        FILES_UPLOADED=0
        if [ -f "$SYNC_OUTPUT" ]; then
            FILES_UPLOADED=$(grep -c "^upload: " "$SYNC_OUTPUT" || true)
            # Ensure it's a valid number
            if ! [[ "$FILES_UPLOADED" =~ ^[0-9]+$ ]]; then
                FILES_UPLOADED=0
            fi
        fi
        TOTAL_FILES_SYNCED=$((TOTAL_FILES_SYNCED + FILES_UPLOADED))
        TOTAL_PATHS_SYNCED=$((TOTAL_PATHS_SYNCED + 1))

        if [ "$FILES_UPLOADED" -gt 0 ]; then
            log_message "  Uploaded $FILES_UPLOADED files"
        fi
    fi

    rm -f "$SYNC_OUTPUT"
done

BACKUP_DURATION=$(($(date +%s) - BACKUP_START))

# Log metrics
STATUS="success"
if [ ${#FAILED_PATHS[@]} -gt 0 ]; then
    STATUS="partial"
fi

logger -t soc2-file-backup "OPERATION_COMPLETE: service=backup operation=file_sync paths_synced=$TOTAL_PATHS_SYNCED files_synced=$TOTAL_FILES_SYNCED status=$STATUS duration_seconds=$BACKUP_DURATION"

# Alert on failures - only email if 3+ paths fail to reduce noise from
# transient file-change races (e.g. user uploading during sync)
if [ ${#FAILED_PATHS[@]} -gt 0 ]; then
    log_message "WARNING: ${#FAILED_PATHS[@]} path(s) failed after retry: ${FAILED_PATHS[*]}"

    if [ ${#FAILED_PATHS[@]} -ge 3 ]; then
        {
            echo "File backup completed with errors on $(hostname)"
            echo ""
            echo "Failed paths (${#FAILED_PATHS[@]} failures - each retried once):"
            printf '%s\n' "${FAILED_PATHS[@]}" | sed 's/^/  - /'
            echo ""
            echo "Check $LOG_FILE for details"
        } | mail -s "[BACKUP ERROR] File Sync - Partial Failure" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    fi
fi

# Daily summary at 8 AM
if [ "$HOUR" = "08" ]; then
    # Calculate total size of protected data
    TOTAL_SIZE=0
    PROTECTED_PATHS=""

    for FILE_PATH in "${FILE_BACKUP_PATHS[@]}"; do
        if [ -d "$FILE_PATH" ]; then
            S3_PATH="s3://$AWS_BACKUP_BUCKET/files${FILE_PATH}/"
            PATH_SIZE=$(aws s3 ls "$S3_PATH" --recursive --summarize 2>/dev/null | grep "Total Size:" | awk '{print $3}' || echo "0")
            TOTAL_SIZE=$((TOTAL_SIZE + PATH_SIZE))

            PATH_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B ${PATH_SIZE:-0} 2>/dev/null || echo "0B")
            PROTECTED_PATHS="$PROTECTED_PATHS
  - $FILE_PATH ($PATH_SIZE_HUMAN)"
        fi
    done

    TOTAL_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B $TOTAL_SIZE 2>/dev/null || echo "0B")

    {
        echo "File Backup Summary - $(hostname)"
        echo "Date: $(date)"
        echo ""
        echo "Protected Business Data: $TOTAL_SIZE_HUMAN total"
        echo ""
        echo "File Paths Being Protected:"
        echo "$PROTECTED_PATHS"
        echo ""
        echo "Backup Strategy:"
        echo "- Upload data: Continuous sync (never delete)"
        echo "- Config/data directories: Every 15 minutes"
        echo "- Source code: GitHub (not backed up here)"
        echo "- Dependencies: Regeneratable (not backed up)"
        echo ""
        echo "Recovery Instructions:"
        echo "1. Restore code from GitHub"
        echo "2. Restore file data: aws s3 sync s3://$AWS_BACKUP_BUCKET/files/ /"
        echo "3. Run deployment scripts to regenerate dependencies"
        echo ""
        echo "This focused approach protects only unique business data,"
        echo "reducing costs while ensuring complete recoverability."
    } | mail -s "[Backup] File Backup Summary - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
fi

log_message "File backup completed"
