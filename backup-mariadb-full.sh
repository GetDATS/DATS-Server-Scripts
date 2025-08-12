#!/bin/bash
set -euo pipefail

# MariaDB full backup - production-ready with comprehensive safety checks
# Direct backup to directory, compress, encrypt, upload, verify, retain, notify

# Load configuration
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/backup.conf

# Use log location from config
LOG_FILE="$MARIADB_FULL_LOG"
DATE_STAMP=$(date +%Y%m%d-%H%M%S)
DAY_OF_WEEK=$(date +%u)  # 1=Monday, 7=Sunday

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
        echo "MariaDB service is down on $(hostname) - no backup possible" | mail -s "[BACKUP ERROR] MariaDB Service Down" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
        exit 1
    fi

    # Check 2: Can we connect to MariaDB?
    log_message "Pre-flight: Testing MariaDB connectivity"
    if ! mariadb --defaults-file="$MARIADB_DEFAULTS_FILE" -e "SELECT 1" >/dev/null 2>&1; then
        log_message "ERROR: Cannot connect to MariaDB"
        echo "Cannot connect to MariaDB on $(hostname) - check credentials" | mail -s "[BACKUP ERROR] MariaDB Connection Failed" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
        exit 1
    fi

    # Check 3: Do we have enough disk space?
    log_message "Pre-flight: Checking disk space"
    DB_SIZE=$(mariadb --defaults-file="$MARIADB_DEFAULTS_FILE" -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 0) AS 'DB Size in MB' FROM information_schema.tables;" -s -N 2>/dev/null || echo "0")
    REQUIRED_SPACE_MB=$((DB_SIZE * 3/2))  # Need space for backup + compressed + overhead
    AVAILABLE_SPACE_MB=$(df -BM "$BACKUP_BASE_DIR" | tail -1 | awk '{print $4}' | sed 's/M//')

    if [ "$AVAILABLE_SPACE_MB" -lt "$REQUIRED_SPACE_MB" ]; then
        log_message "ERROR: Insufficient disk space (need ${REQUIRED_SPACE_MB}MB, have ${AVAILABLE_SPACE_MB}MB)"
        echo "Insufficient disk space for backup on $(hostname) - need ${REQUIRED_SPACE_MB}MB, have ${AVAILABLE_SPACE_MB}MB" | mail -s "[BACKUP ERROR] Disk Space Critical" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
        exit 1
    fi
    log_message "Pre-flight: Disk space OK (${AVAILABLE_SPACE_MB}MB available, ${REQUIRED_SPACE_MB}MB needed)"

    # Check 4: Are config files readable?
    log_message "Pre-flight: Checking configuration files"
    if [ ! -r "$MARIADB_DEFAULTS_FILE" ]; then
        log_message "ERROR: Cannot read MariaDB defaults file: $MARIADB_DEFAULTS_FILE"
        checks_passed=false
    fi

    # Check 5: If we have an encryption key, can we use it?
    if [ -f "$BACKUP_ENCRYPTION_KEY" ]; then
        log_message "Pre-flight: Testing encryption key"
        if ! echo "test" | openssl enc -aes-256-cbc -salt -pbkdf2 -pass file:"$BACKUP_ENCRYPTION_KEY" >/dev/null 2>&1; then
            log_message "ERROR: Encryption key exists but appears invalid"
            echo "Encryption key is corrupted on $(hostname) - backups will not be encrypted" | mail -s "[BACKUP WARNING] Encryption Key Invalid" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
            # Don't exit - we can still do unencrypted backups
        fi
    fi

    # Check 6: Can we write to backup directory?
    log_message "Pre-flight: Checking backup directory permissions"
    if ! touch "$BACKUP_BASE_DIR/.write_test" 2>/dev/null; then
        log_message "ERROR: Cannot write to backup directory: $BACKUP_BASE_DIR"
        checks_passed=false
    else
        rm -f "$BACKUP_BASE_DIR/.write_test"
    fi

    if [ "$checks_passed" = false ]; then
        log_message "ERROR: Pre-flight checks failed"
        exit 1
    fi

    log_message "Pre-flight: All checks passed"
}

log_message "Starting MariaDB full backup - $DATE_STAMP"
BACKUP_START=$(date +%s)

# Create backup directories
mkdir -p "$BACKUP_BASE_DIR" "$BACKUP_LOG_DIR"

# Run pre-flight checks before we commit to anything
preflight_checks

# Step 1: Create backup in a directory (not streamed)
BACKUP_DIR="$BACKUP_BASE_DIR/backup-$DATE_STAMP"
log_message "Creating backup in: $BACKUP_DIR"

# Convert array to space-separated string for mariadb-backup
if mariadb-backup --defaults-file="$MARIADB_DEFAULTS_FILE" --backup --target-dir="$BACKUP_DIR" 2>&1 | tee -a "$LOG_FILE"; then
    log_message "Backup created successfully"
else
    log_message "ERROR: Backup creation failed"
    # Clean up partial backup if it exists
    [ -d "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR"
    echo "MariaDB backup failed on $(hostname)" | mail -s "[BACKUP ERROR] MariaDB Full Backup Failed" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1
fi

# Step 1.5: Verify backup integrity before we waste time compressing garbage
log_message "Verifying backup integrity"
VERIFY_DIR="$BACKUP_BASE_DIR/verify-$DATE_STAMP"
cp -r "$BACKUP_DIR" "$VERIFY_DIR"

if mariadb-backup --prepare --target-dir="$VERIFY_DIR" >/dev/null 2>&1; then
    log_message "Backup integrity verified"
    rm -rf "$VERIFY_DIR"
else
    log_message "ERROR: Backup failed integrity check - data may be corrupted"
    rm -rf "$BACKUP_DIR" "$VERIFY_DIR"
    echo "MariaDB backup failed integrity check on $(hostname) - backup data corrupted" | mail -s "[BACKUP ERROR] Backup Integrity Failed" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1
fi

# Step 2: Compress the backup directory
COMPRESSED_FILE="$BACKUP_BASE_DIR/mariadb-$DATE_STAMP.tar.bz2"
log_message "Compressing backup to: $COMPRESSED_FILE"

if tar -cf - -C "$BACKUP_BASE_DIR" "backup-$DATE_STAMP" | nice -n 19 ionice -c2 -n7 pbzip2 -p16 -c > "$COMPRESSED_FILE"; then
    log_message "Compression completed"
    # Remove uncompressed directory to save space
    rm -rf "$BACKUP_DIR"
else
    log_message "ERROR: Compression failed"
    rm -rf "$BACKUP_DIR"
    exit 1
fi

# Get compressed size for reporting
BACKUP_SIZE=$(stat -c%s "$COMPRESSED_FILE" 2>/dev/null || echo "0")
BACKUP_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B $BACKUP_SIZE 2>/dev/null || echo "$BACKUP_SIZE bytes")

# Step 3: Encrypt the backup (if key exists and is valid)
UPLOAD_FILE="$COMPRESSED_FILE"
S3_FILENAME="mariadb-$DATE_STAMP.tar.bz2"
ENCRYPTION_USED="No"

if [ -f "$BACKUP_ENCRYPTION_KEY" ]; then
    ENCRYPTED_FILE="${COMPRESSED_FILE}.enc"
    log_message "Encrypting backup"

    if openssl enc -aes-256-cbc -salt -pbkdf2 -in "$COMPRESSED_FILE" -out "$ENCRYPTED_FILE" -pass file:"$BACKUP_ENCRYPTION_KEY"; then
        log_message "Encryption completed"
        rm -f "$COMPRESSED_FILE"  # Remove unencrypted file
        UPLOAD_FILE="$ENCRYPTED_FILE"
        S3_FILENAME="${S3_FILENAME}.enc"
        ENCRYPTION_USED="Yes"
    else
        log_message "WARNING: Encryption failed, uploading unencrypted"
    fi
else
    log_message "No encryption key found, uploading unencrypted"
fi

# Step 4: Upload to S3
S3_PATH="s3://$AWS_BACKUP_BUCKET/mariadb-full/$(hostname)/$(date +%Y/%m)/$S3_FILENAME"
log_message "Uploading to: $S3_PATH"

UPLOAD_START=$(date +%s)
if aws s3 cp "$UPLOAD_FILE" "$S3_PATH"; then
    UPLOAD_END=$(date +%s)
    UPLOAD_DURATION=$((UPLOAD_END - UPLOAD_START))
    log_message "Upload completed successfully in ${UPLOAD_DURATION} seconds"
    UPLOAD_SUCCESS=true
else
    log_message "ERROR: Upload to S3 failed"
    UPLOAD_SUCCESS=false
fi

# Step 5: Verify the upload
if [ "$UPLOAD_SUCCESS" = true ]; then
    log_message "Verifying S3 upload"

    if aws s3 ls "$S3_PATH" >/dev/null 2>&1; then
        S3_SIZE=$(aws s3api head-object --bucket "$AWS_BACKUP_BUCKET" --key "mariadb-full/$(hostname)/$(date +%Y/%m)/$S3_FILENAME" --query 'ContentLength' --output text 2>/dev/null || echo "0")

        # Calculate the size difference percentage
        if [ "$BACKUP_SIZE" -gt 0 ]; then
            SIZE_DIFF=$((S3_SIZE - BACKUP_SIZE))
            SIZE_DIFF_ABS=${SIZE_DIFF#-}  # Absolute value
            SIZE_DIFF_PERCENT=$((SIZE_DIFF_ABS * 100 / BACKUP_SIZE))

            # Only fail if the difference is more than 1% or if S3 is smaller
            if [ "$SIZE_DIFF_PERCENT" -gt 1 ] || [ "$S3_SIZE" -lt "$BACKUP_SIZE" ]; then
                log_message "ERROR: Significant size mismatch - S3: $S3_SIZE, Local: $BACKUP_SIZE (${SIZE_DIFF_PERCENT}% difference)"
                VERIFY_SUCCESS=false
            else
                log_message "Upload verified - S3: $S3_SIZE, Local: $BACKUP_SIZE (${SIZE_DIFF_PERCENT}% difference acceptable)"
                VERIFY_SUCCESS=true
            fi
        else
            log_message "ERROR: Local file size is 0"
            VERIFY_SUCCESS=false
        fi
    else
        log_message "WARNING: Cannot verify S3 upload"
        VERIFY_SUCCESS=false
    fi
else
    VERIFY_SUCCESS=false
fi

# Step 6: Clean up old local backups (keep 7 days)
log_message "Cleaning local backups older than $LOCAL_RETAIN_DAYS days"
CLEANED_COUNT=$(find "$BACKUP_BASE_DIR" -name "mariadb-*.tar.bz2*" -mtime +$LOCAL_RETAIN_DAYS -print -delete 2>/dev/null | wc -l || echo "0")
if [ "$CLEANED_COUNT" -gt 0 ]; then
    log_message "Removed $CLEANED_COUNT old backup(s)"
fi

# Count remaining local backups
LOCAL_COUNT=$(find "$BACKUP_BASE_DIR" -name "mariadb-*.tar.bz2*" 2>/dev/null | wc -l)
LOCAL_TOTAL_SIZE=$(du -sh "$BACKUP_BASE_DIR" 2>/dev/null | cut -f1 || echo "Unknown")

# Calculate backup duration
BACKUP_END=$(date +%s)
BACKUP_DURATION=$((BACKUP_END - BACKUP_START))

# Determine overall status for subject line
if [ "$UPLOAD_SUCCESS" = true ] && [ "$VERIFY_SUCCESS" = true ]; then
    BACKUP_STATUS="Success"
    STATUS_EMOJI="✅"
else
    BACKUP_STATUS="FAILED"
    STATUS_EMOJI="❌"
fi

# Step 7: Send appropriate email based on day of week
if [ "$DAY_OF_WEEK" = "1" ] || [ "$BACKUP_STATUS" = "FAILED" ]; then
    # Monday = weekly detailed report, or any day if backup failed
    {
        echo "MariaDB Full Backup Report - $(hostname)"
        echo "Date: $(date)"
        echo ""
        echo "Backup Summary:"
        echo "- Timestamp: $DATE_STAMP"
        echo "- Duration: ${BACKUP_DURATION} seconds"
        echo "- Size: $BACKUP_SIZE_HUMAN"
        echo "- Encryption: $ENCRYPTION_USED"
        echo ""
        echo "Status:"
        echo "- Local backup: $([ -f "$UPLOAD_FILE" ] && echo "✓ Success" || echo "✗ Failed")"
        echo "- S3 upload: $([ "$UPLOAD_SUCCESS" = true ] && echo "✓ Success" || echo "✗ Failed")"
        echo "- Verification: $([ "$VERIFY_SUCCESS" = true ] && echo "✓ Verified" || echo "⚠ Not verified")"
        echo ""
        echo "Storage:"
        echo "- S3 location: $S3_PATH"
        echo "- Local backups: $LOCAL_COUNT files, $LOCAL_TOTAL_SIZE total"
        echo "- Local retention: $LOCAL_RETAIN_DAYS days"
        echo "- S3 retention: $S3_RETAIN_MARIADB_FULL days"
        echo ""

        if [ "$UPLOAD_SUCCESS" = true ] && [ "$VERIFY_SUCCESS" = true ]; then
            echo "Recovery Instructions:"
            echo "1. Download: aws s3 cp $S3_PATH backup.tar.bz2.enc"
            if [ "$ENCRYPTION_USED" = "Yes" ]; then
                echo "2. Decrypt: openssl enc -aes-256-cbc -d -pbkdf2 -in backup.tar.bz2.enc -out backup.tar.bz2 -pass file:/root/.backup-encryption-key"
                echo "3. Extract: pbzip2 -dvc backup.tar.bz2 | tar -xv"
            else
                echo "2. Extract: pbzip2 -dvc backup.tar.bz2 | tar -xv"
            fi
            echo "3. Prepare: mariadb-backup --prepare --target-dir=backup-$DATE_STAMP"
            echo "4. Stop MariaDB: systemctl stop mariadb"
            echo "5. Restore: mariadb-backup --copy-back --target-dir=backup-$DATE_STAMP"
            echo "6. Fix permissions: chown -R mysql:mysql /var/lib/mysql"
            echo "7. Start MariaDB: systemctl start mariadb"
        else
            echo "⚠️  ACTION REQUIRED:"
            echo "Backup did not complete successfully. Please investigate immediately."
            echo "Check log: $LOG_FILE"
        fi

    } | mail -s "[Backup] MariaDB Full - $BACKUP_STATUS - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
else
    # Daily brief status email
    {
        echo "$STATUS_EMOJI MariaDB backup completed on $(hostname)"
        echo ""
        echo "Size: $BACKUP_SIZE_HUMAN | Duration: ${BACKUP_DURATION}s | Encrypted: $ENCRYPTION_USED"
        echo "Local: $LOCAL_COUNT backups ($LOCAL_TOTAL_SIZE) | S3: Verified"
        echo ""
        echo "Full report every Monday. Detailed log: $LOG_FILE"
    } | mail -s "[Backup] MariaDB Daily - $BACKUP_STATUS - $(hostname)" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"
fi

# Log final status with structured metrics
if [ "$UPLOAD_SUCCESS" = true ] && [ "$VERIFY_SUCCESS" = true ]; then
    log_message "Backup completed successfully"
    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_full status=success size_bytes=$BACKUP_SIZE duration_seconds=$BACKUP_DURATION encrypted=$ENCRYPTION_USED"
else
    log_message "Backup completed with issues"
    logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=mariadb_full status=warning size_bytes=$BACKUP_SIZE duration_seconds=$BACKUP_DURATION upload=$UPLOAD_SUCCESS verify=$VERIFY_SUCCESS encrypted=$ENCRYPTION_USED"
fi