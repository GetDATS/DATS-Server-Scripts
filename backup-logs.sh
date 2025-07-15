#!/bin/bash
set -euo pipefail

# Log archive backup - ships rotated logs to S3 for compliance
# Archives rotated logs daily, with state tracking to avoid re-uploads

# Load configuration
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/backup.conf

LOG_FILE="$LOG_ARCHIVE_LOG"
DATE_STAMP=$(date +%Y%m%d)
DAY_OF_WEEK=$(date +%u)
TEMP_DIR=$(mktemp -d)

# Simple logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    logger -t soc2-backup "$1"
}

# Cleanup on exit
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Pre-flight checks
preflight_checks() {
    local checks_passed=true

    # Check 1: Can we write to temp location?
    log_message "Pre-flight: Checking temp directory"
    if [ ! -d "$TEMP_DIR" ] || [ ! -w "$TEMP_DIR" ]; then
        log_message "ERROR: Cannot write to temp directory"
        checks_passed=false
    fi

    # Check 2: Are AWS credentials configured?
    log_message "Pre-flight: Checking AWS credentials"
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_message "ERROR: AWS credentials not configured or invalid"
        echo "AWS credentials invalid on $(hostname) - logs cannot be archived" | mail -s "[BACKUP ERROR] AWS Credentials Invalid" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
        exit 1
    fi

    # Check 3: Can we access the S3 bucket?
    log_message "Pre-flight: Checking S3 bucket access"
    if ! aws s3 ls "s3://$AWS_BACKUP_BUCKET" >/dev/null 2>&1; then
        log_message "ERROR: Cannot access S3 bucket: $AWS_BACKUP_BUCKET"
        checks_passed=false
    fi

    # Check 4: Does /var/log exist and is readable?
    log_message "Pre-flight: Checking log directory"
    if [ ! -d "/var/log" ] || [ ! -r "/var/log" ]; then
        log_message "ERROR: Cannot read /var/log directory"
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
    mkdir -p "$(dirname "$LOG_ARCHIVE_STATE_FILE")"

    if [ ! -f "$LOG_ARCHIVE_STATE_FILE" ]; then
        touch "$LOG_ARCHIVE_STATE_FILE"
        log_message "Created new state tracking file"
    else
        # Validate state file
        local line_count=$(wc -l < "$LOG_ARCHIVE_STATE_FILE" 2>/dev/null || echo "0")
        if [ "$line_count" -gt 50000 ]; then
            log_message "WARNING: State file has $line_count entries - rotating"
            mv "$LOG_ARCHIVE_STATE_FILE" "${LOG_ARCHIVE_STATE_FILE}.old.$(date +%Y%m%d)"
            touch "$LOG_ARCHIVE_STATE_FILE"
        fi
    fi
}

log_message "Starting log archive backup"
BACKUP_START=$(date +%s)

# Run pre-flight checks
preflight_checks

# Initialize state tracking
initialize_state

# Find rotated logs (simpler approach - look for common rotation patterns)
log_message "Scanning for rotated logs"

# Build list of rotated logs, excluding already archived ones
ROTATED_LOGS=""
for pattern in "*.1" "*.1.gz" "*-$(date -d yesterday +%Y%m%d)*" "*-$(date -d yesterday +%Y%m%d)*.gz"; do
    while IFS= read -r -d '' logfile; do
        # Get just the filename
        filename=$(basename "$logfile")

        # Skip if already archived
        if grep -q "^${filename}$" "$LOG_ARCHIVE_STATE_FILE" 2>/dev/null; then
            continue
        fi

        # Skip if it's today's active log
        if [[ "$filename" =~ $(date +%Y%m%d) ]] && [ "$(date +%Y%m%d)" != "$(date -d yesterday +%Y%m%d)" ]; then
            continue
        fi

        # Add to our list
        ROTATED_LOGS="${ROTATED_LOGS}${logfile}"$'\n'
    done < <(find /var/log -type f -name "$pattern" -print0 2>/dev/null)
done

# Remove empty lines and count
ROTATED_LOGS=$(echo "$ROTATED_LOGS" | grep -v "^$" || true)
if [ -z "$ROTATED_LOGS" ]; then
    FILE_COUNT=0
else
    FILE_COUNT=$(echo "$ROTATED_LOGS" | wc -l | tr -d ' ')
fi

if [ "$FILE_COUNT" -eq 0 ]; then
    log_message "No new rotated logs found to archive"
    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=log_archive archived=0 size_bytes=0 status=success duration_seconds=$(($(date +%s) - BACKUP_START))"

    # Still send weekly summary on Mondays
    if [ "$DAY_OF_WEEK" = "1" ]; then
        {
            echo "📋 Log Archive Weekly Summary - $(hostname)"
            echo ""
            echo "No new rotated logs found this week."
            echo ""
            echo "This is normal when:"
            echo "- Logs haven't rotated yet"
            echo "- All rotated logs have already been archived"
            echo "- Log rotation schedule doesn't align with daily checks"
            echo ""
            echo "Current retention policy: $S3_RETAIN_LOGS days"
            echo "Archive location: s3://$AWS_BACKUP_BUCKET/logs/$(hostname)/"
        } | mail -s "[Backup] Log Archive Weekly - ✅ $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    fi
    exit 0
fi

# Create archive
ARCHIVE_PATH="$TEMP_DIR/logs-$DATE_STAMP.tar.gz"
log_message "Creating archive with $FILE_COUNT log files"

# Create tar archive
echo "$ROTATED_LOGS" | tar czf "$ARCHIVE_PATH" -T - 2>/dev/null

ARCHIVE_SIZE=$(stat -c%s "$ARCHIVE_PATH" 2>/dev/null || echo "0")
ARCHIVE_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B $ARCHIVE_SIZE 2>/dev/null || echo "0B")
log_message "Archive created: $ARCHIVE_SIZE_HUMAN"

# Upload to S3 with immediate Glacier IR transition
S3_PATH="s3://$AWS_BACKUP_BUCKET/logs/$(hostname)/$(date +%Y/%m)/logs-$DATE_STAMP.tar.gz"
log_message "Uploading to: $S3_PATH"

UPLOAD_START=$(date +%s)
if aws s3 cp "$ARCHIVE_PATH" "$S3_PATH" --storage-class GLACIER_IR; then
    UPLOAD_DURATION=$(($(date +%s) - UPLOAD_START))
    log_message "Upload completed in ${UPLOAD_DURATION}s"
    UPLOAD_STATUS="success"

    # Verify upload
    log_message "Verifying upload"
    S3_SIZE=$(aws s3api head-object --bucket "$AWS_BACKUP_BUCKET" --key "logs/$(hostname)/$(date +%Y/%m)/logs-$DATE_STAMP.tar.gz" --query 'ContentLength' --output text 2>/dev/null || echo "0")

    if [ "$S3_SIZE" = "$ARCHIVE_SIZE" ]; then
        log_message "Upload verified - sizes match"
        VERIFY_STATUS="success"

        # Mark all files as archived
        echo "$ROTATED_LOGS" | while IFS= read -r logfile; do
            [ -n "$logfile" ] && echo "$(basename "$logfile")" >> "$LOG_ARCHIVE_STATE_FILE"
        done

        # Log success metrics
        logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=log_archive archived=$FILE_COUNT size_bytes=$ARCHIVE_SIZE status=success duration_seconds=$(($(date +%s) - BACKUP_START))"
    else
        log_message "WARNING: Upload verification failed - size mismatch"
        VERIFY_STATUS="failed"
        UPLOAD_STATUS="warning"
    fi
else
    log_message "ERROR: Upload failed"
    UPLOAD_STATUS="failed"
    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=log_archive archived=0 size_bytes=$ARCHIVE_SIZE status=error duration_seconds=$(($(date +%s) - BACKUP_START))"

    echo "Log archive upload failed on $(hostname) - check AWS connectivity" | mail -s "[BACKUP ERROR] Log Archive Upload Failed" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1
fi

# Clean up old state entries for logs that no longer exist
if [ -f "$LOG_ARCHIVE_STATE_FILE" ] && [ -s "$LOG_ARCHIVE_STATE_FILE" ]; then
    TEMP_STATE=$(mktemp)
    CLEANED_COUNT=0

    while IFS= read -r archived_log; do
        # Check if file still exists anywhere in /var/log
        if find /var/log -name "$archived_log" -type f 2>/dev/null | grep -q .; then
            echo "$archived_log" >> "$TEMP_STATE"
        else
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
        fi
    done < "$LOG_ARCHIVE_STATE_FILE"

    if [ "$CLEANED_COUNT" -gt 0 ]; then
        log_message "Removed $CLEANED_COUNT deleted logs from state file"
        mv "$TEMP_STATE" "$LOG_ARCHIVE_STATE_FILE"
    else
        rm -f "$TEMP_STATE"
    fi
fi

# Send appropriate notification
if [ "$DAY_OF_WEEK" = "1" ] || [ "$UPLOAD_STATUS" != "success" ]; then
    # Monday or any failure - detailed report
    {
        echo "📋 Log Archive Report - $(hostname)"
        echo "Date: $(date)"
        echo ""
        echo "Archive Summary:"
        echo "- Files archived: $FILE_COUNT"
        echo "- Archive size: $ARCHIVE_SIZE_HUMAN"
        echo "- Upload status: $UPLOAD_STATUS"
        echo "- Verification: $VERIFY_STATUS"
        echo ""
        echo "Storage Details:"
        echo "- S3 location: $S3_PATH"
        echo "- Storage class: GLACIER_IR (immediate archival)"
        echo "- Retention: $S3_RETAIN_LOGS days"
        echo ""

        if [ "$UPLOAD_STATUS" = "success" ]; then
            echo "Archived Logs Include:"
            echo "- System logs (syslog, auth, kern)"
            echo "- Application logs (apache, php, mysql)"
            echo "- Security logs (fail2ban, aide, clamav)"
            echo "- Audit logs (audit.log)"
            echo ""
            echo "Recovery Instructions:"
            echo "1. List available archives:"
            echo "   aws s3 ls s3://$AWS_BACKUP_BUCKET/logs/$(hostname)/"
            echo "2. Download specific archive:"
            echo "   aws s3 cp $S3_PATH logs.tar.gz"
            echo "3. Extract logs:"
            echo "   tar xzf logs.tar.gz"
            echo ""
            echo "Note: Glacier IR retrieval is typically instant but may"
            echo "take up to 12 hours in rare cases."
        else
            echo "⚠️  ACTION REQUIRED:"
            echo "Log archive did not complete successfully."
            echo "Check $LOG_FILE for details."
        fi
    } | mail -s "[Backup] Log Archive - $([ "$UPLOAD_STATUS" = "success" ] && echo "✅" || echo "❌") $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
else
    # Daily brief summary
    {
        echo "✅ Log archive completed on $(hostname)"
        echo ""
        echo "Archived: $FILE_COUNT files ($ARCHIVE_SIZE_HUMAN)"
        echo "Location: Glacier IR | Retention: $S3_RETAIN_LOGS days"
        echo ""
        echo "Full report every Monday."
    } | mail -s "[Backup] Logs - ✅ $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
fi

log_message "Log archive completed successfully"