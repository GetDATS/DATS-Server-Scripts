#!/bin/bash
set -euo pipefail

# AWS backup sync script - uploads staged backups to S3
# Runs daily, manages lifecycle and cleanup

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/aws-sync.conf

LOG_FILE="/var/log/backups/aws-sync.log"
DATE_STAMP=$(date +%Y%m%d-%H%M%S)
STAGING_BASE="$BACKUP_BASE/aws-staging"

# Datadog-friendly logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    logger -t aws-backup "$1"
}

log_message "Starting AWS backup sync - $DATE_STAMP"

# Check AWS credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_message "ERROR: AWS credentials not configured or invalid"
    echo "AWS backup sync failed - invalid credentials on $(hostname)" | mail -s "[BACKUP ERROR] AWS Credentials Invalid" "$ADMIN_EMAIL"
    exit 1
fi

# Check if S3 bucket exists
if ! aws s3 ls "s3://$AWS_BUCKET" >/dev/null 2>&1; then
    log_message "ERROR: S3 bucket $AWS_BUCKET not accessible"
    echo "AWS backup sync failed - bucket not accessible on $(hostname)" | mail -s "[BACKUP ERROR] S3 Bucket Inaccessible" "$ADMIN_EMAIL"
    exit 1
fi

UPLOAD_START=$(date +%s)
TOTAL_UPLOADED=0
TOTAL_SIZE="0"

# Function to upload files from a staging directory
upload_files() {
    local source_dir="$1"
    local s3_prefix="$2"
    local file_pattern="$3"

    if [ ! -d "$source_dir" ]; then
        log_message "Staging directory $source_dir does not exist, skipping"
        return 0
    fi

    # Find files matching pattern
    local files=($(find "$source_dir" -name "$file_pattern" -type f 2>/dev/null || true))

    if [ ${#files[@]} -eq 0 ]; then
        log_message "No files matching $file_pattern in $source_dir"
        return 0
    fi

    for file in "${files[@]}"; do
        local filename=$(basename "$file")
        local s3_key="$s3_prefix/$filename"

        log_message "Uploading: $filename"

        if aws s3 cp "$file" "s3://$AWS_BUCKET/$s3_key" \
           --storage-class STANDARD \
           --server-side-encryption AES256 2>&1 | tee -a "$LOG_FILE"; then

            local file_size=$(du -sh "$file" | cut -f1)
            log_message "Upload successful: $filename ($file_size)"

            # Log for Datadog
            logger -t aws-backup "FILE_UPLOADED: file=$filename size=$file_size s3_key=$s3_key"

            # Update counters
            TOTAL_UPLOADED=$((TOTAL_UPLOADED + 1))
            TOTAL_SIZE="${TOTAL_SIZE}, $file_size"

            # Remove successfully uploaded file
            rm -f "$file"
            log_message "Removed staged file: $filename"

        else
            log_message "ERROR: Upload failed for $filename"
            echo "AWS upload failed for $filename on $(hostname)" | mail -s "[BACKUP ERROR] AWS Upload Failed" "$ADMIN_EMAIL"
            return 1
        fi
    done

    return 0
}

# Upload MariaDB backups
log_message "Uploading MariaDB backups"
upload_files "$STAGING_BASE/mariadb" "mariadb/$(date +%Y/%m)" "mariadb-daily-*.tar.gz"

# Upload Borg backups
log_message "Uploading Borg backups"
upload_files "$STAGING_BASE/borg" "borg/$(date +%Y/%m)" "borg-weekly-*.tar.gz"

UPLOAD_END=$(date +%s)
UPLOAD_DURATION=$((UPLOAD_END - UPLOAD_START))

# Log structured metrics for Datadog
logger -t aws-backup "SYNC_COMPLETE: files_uploaded=$TOTAL_UPLOADED duration=${UPLOAD_DURATION}s bucket=$AWS_BUCKET"

# Verify bucket lifecycle policy is still applied
log_message "Verifying S3 lifecycle policy"
if aws s3api get-bucket-lifecycle-configuration --bucket "$AWS_BUCKET" >/dev/null 2>&1; then
    log_message "S3 lifecycle policy verified"
else
    log_message "WARNING: S3 lifecycle policy missing or inaccessible"
    echo "S3 lifecycle policy issue detected on bucket $AWS_BUCKET" | mail -s "[BACKUP WARNING] S3 Lifecycle Policy Issue" "$ADMIN_EMAIL"
fi

# Get current bucket statistics
BUCKET_SIZE=$(aws s3 ls "s3://$AWS_BUCKET" --recursive --summarize 2>/dev/null | grep "Total Size" | awk '{print $3}' || echo "Unknown")
BUCKET_OBJECTS=$(aws s3 ls "s3://$AWS_BUCKET" --recursive --summarize 2>/dev/null | grep "Total Objects" | awk '{print $3}' || echo "Unknown")

log_message "S3 bucket statistics: $BUCKET_OBJECTS objects, $BUCKET_SIZE bytes total"

# Clean up empty staging directories
find "$STAGING_BASE" -type d -empty -delete 2>/dev/null || true

# Send success notification
if [ "$TOTAL_UPLOADED" -gt 0 ]; then
    EMAIL_SUBJECT="[Backup] AWS Sync - $TOTAL_UPLOADED files uploaded - $(hostname)"
    EMAIL_BODY="AWS backup sync completed successfully on $(hostname)

Sync Details:
- Files uploaded: $TOTAL_UPLOADED
- Duration: ${UPLOAD_DURATION} seconds
- Total sizes: ${TOTAL_SIZE#, }

S3 Bucket Statistics:
- Total objects: $BUCKET_OBJECTS
- Total size: $BUCKET_SIZE bytes
- Bucket: $AWS_BUCKET

AWS storage lifecycle:
- Days 1-30: S3 Standard
- Days 31-90: S3 IA
- Days 91-365: Glacier
- Day 366+: Deleted

View backup metrics in your Datadog dashboard."

else
    EMAIL_SUBJECT="[Backup] AWS Sync - No files to upload - $(hostname)"
    EMAIL_BODY="AWS backup sync completed on $(hostname)

No staged files found for upload.
This is normal if no daily/weekly backups were staged today.

S3 Bucket Statistics:
- Total objects: $BUCKET_OBJECTS
- Total size: $BUCKET_SIZE bytes
- Bucket: $AWS_BUCKET

View backup metrics in your Datadog dashboard."
fi

echo "$EMAIL_BODY" | mail -s "$EMAIL_SUBJECT" "$ADMIN_EMAIL"

log_message "AWS sync completed - $TOTAL_UPLOADED files uploaded"