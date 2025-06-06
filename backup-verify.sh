#!/bin/bash
set -euo pipefail

# Backup verification script for SOC 2 compliance
# Runs weekly to verify backup integrity and restore capability

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/borg-backup.conf
source /usr/local/share/soc2-scripts/config/aws-sync.conf

LOG_FILE="/var/log/backups/backup-verify.log"
DATE_STAMP=$(date +%Y%m%d-%H%M%S)
VERIFY_DIR="/tmp/backup-verify-$DATE_STAMP"

# Export borg environment variables
export BORG_REPO
export BORG_PASSPHRASE

# Datadog-friendly logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    logger -t backup-verify "$1"
}

# Cleanup function
cleanup() {
    if [ -d "$VERIFY_DIR" ]; then
        rm -rf "$VERIFY_DIR"
        log_message "Cleaned up verification directory"
    fi
}
trap cleanup EXIT

log_message "Starting backup verification - $DATE_STAMP"

VERIFY_START=$(date +%s)
TESTS_PASSED=0
TESTS_FAILED=0

# Function to record test results
test_result() {
    local test_name="$1"
    local result="$2"

    if [ "$result" = "PASS" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_message "✓ $test_name: PASSED"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_message "✗ $test_name: FAILED"
    fi
}

# Create verification directory
mkdir -p "$VERIFY_DIR"

# Test 1: Borg repository integrity
log_message "Testing Borg repository integrity"
if borg check "$BORG_REPO" 2>&1 | tee -a "$LOG_FILE"; then
    test_result "Borg Repository Integrity" "PASS"
else
    test_result "Borg Repository Integrity" "FAIL"
fi

# Test 2: Borg archive listing
log_message "Testing Borg archive listing"
LATEST_ARCHIVE=$(borg list --short "$BORG_REPO" | tail -1)
if [ -n "$LATEST_ARCHIVE" ]; then
    test_result "Borg Archive Listing" "PASS"
    log_message "Latest archive: $LATEST_ARCHIVE"
else
    test_result "Borg Archive Listing" "FAIL"
fi

# Test 3: Borg partial restore test
if [ -n "$LATEST_ARCHIVE" ]; then
    log_message "Testing Borg partial restore"
    RESTORE_TEST_DIR="$VERIFY_DIR/borg-restore-test"
    mkdir -p "$RESTORE_TEST_DIR"

    if borg extract --dry-run "$BORG_REPO::$LATEST_ARCHIVE" etc/hostname 2>&1 | tee -a "$LOG_FILE"; then
        test_result "Borg Restore Test (dry-run)" "PASS"
    else
        test_result "Borg Restore Test (dry-run)" "FAIL"
    fi
fi

# Test 4: MariaDB backup verification
log_message "Testing MariaDB backup verification"
LATEST_MARIADB_BACKUP=$(find "$BACKUP_BASE/mariadb" -name "backup-*" -type d | sort | tail -1)
if [ -n "$LATEST_MARIADB_BACKUP" ] && [ -d "$LATEST_MARIADB_BACKUP" ]; then
    test_result "MariaDB Backup Exists" "PASS"
    log_message "Latest MariaDB backup: $LATEST_MARIADB_BACKUP"

    # Check if backup has key files
    if [ -f "$LATEST_MARIADB_BACKUP/xtrabackup_info" ] && [ -f "$LATEST_MARIADB_BACKUP/backup-my.cnf" ]; then
        test_result "MariaDB Backup Structure" "PASS"
    else
        test_result "MariaDB Backup Structure" "FAIL"
    fi

    # Test backup preparation (dry run)
    PREPARE_TEST_DIR="$VERIFY_DIR/mariadb-prepare-test"
    mkdir -p "$PREPARE_TEST_DIR"
    cp -r "$LATEST_MARIADB_BACKUP" "$PREPARE_TEST_DIR/"

    BACKUP_NAME=$(basename "$LATEST_MARIADB_BACKUP")
    if mariadb-backup --prepare --target-dir="$PREPARE_TEST_DIR/$BACKUP_NAME" 2>&1 | tee -a "$LOG_FILE"; then
        test_result "MariaDB Backup Preparation" "PASS"
    else
        test_result "MariaDB Backup Preparation" "FAIL"
    fi
else
    test_result "MariaDB Backup Exists" "FAIL"
fi

# Test 5: AWS connectivity and bucket access
log_message "Testing AWS connectivity"
if aws s3 ls "s3://$AWS_BUCKET" >/dev/null 2>&1; then
    test_result "AWS S3 Connectivity" "PASS"

    # Count objects in bucket
    BUCKET_OBJECTS=$(aws s3 ls "s3://$AWS_BUCKET" --recursive | wc -l)
    log_message "S3 bucket contains $BUCKET_OBJECTS objects"

    if [ "$BUCKET_OBJECTS" -gt 0 ]; then
        test_result "AWS S3 Bucket Content" "PASS"
    else
        test_result "AWS S3 Bucket Content" "FAIL"
    fi
else
    test_result "AWS S3 Connectivity" "FAIL"
fi

# Test 6: Backup age verification
log_message "Testing backup age requirements"
CURRENT_TIME=$(date +%s)

# Check Borg backup age
if [ -n "$LATEST_ARCHIVE" ]; then
    BORG_INFO=$(borg info "$BORG_REPO::$LATEST_ARCHIVE" 2>/dev/null | grep "Time (start)" | cut -d: -f2- | xargs)
    BORG_TIMESTAMP=$(date -d "$BORG_INFO" +%s 2>/dev/null || echo "0")
    BORG_AGE_HOURS=$(((CURRENT_TIME - BORG_TIMESTAMP) / 3600))

    if [ "$BORG_AGE_HOURS" -le 12 ]; then
        test_result "Borg Backup Age (<12h)" "PASS"
        log_message "Borg backup age: ${BORG_AGE_HOURS} hours"
    else
        test_result "Borg Backup Age (<12h)" "FAIL"
        log_message "Borg backup age: ${BORG_AGE_HOURS} hours (too old)"
    fi
fi

# Check MariaDB backup age
if [ -n "$LATEST_MARIADB_BACKUP" ]; then
    MARIADB_TIMESTAMP=$(stat -c %Y "$LATEST_MARIADB_BACKUP")
    MARIADB_AGE_HOURS=$(((CURRENT_TIME - MARIADB_TIMESTAMP) / 3600))

    if [ "$MARIADB_AGE_HOURS" -le 2 ]; then
        test_result "MariaDB Backup Age (<2h)" "PASS"
        log_message "MariaDB backup age: ${MARIADB_AGE_HOURS} hours"
    else
        test_result "MariaDB Backup Age (<2h)" "FAIL"
        log_message "MariaDB backup age: ${MARIADB_AGE_HOURS} hours (too old)"
    fi
fi

VERIFY_END=$(date +%s)
VERIFY_DURATION=$((VERIFY_END - VERIFY_START))
TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED))

# Log structured metrics for Datadog
logger -t backup-verify "VERIFICATION_COMPLETE: tests_passed=$TESTS_PASSED tests_failed=$TESTS_FAILED total_tests=$TOTAL_TESTS duration=${VERIFY_DURATION}s"

# Generate verification report
VERIFICATION_STATUS="FAILED"
if [ "$TESTS_FAILED" -eq 0 ]; then
    VERIFICATION_STATUS="PASSED"
fi

# Send notification email
EMAIL_SUBJECT="[Backup] Weekly Verification - $VERIFICATION_STATUS - $(hostname)"
EMAIL_BODY="Backup verification completed on $(hostname)

Verification Summary:
- Status: $VERIFICATION_STATUS
- Tests passed: $TESTS_PASSED
- Tests failed: $TESTS_FAILED
- Total tests: $TOTAL_TESTS
- Duration: ${VERIFY_DURATION} seconds

Test Results:"

if [ "$TESTS_FAILED" -gt 0 ]; then
    EMAIL_BODY="$EMAIL_BODY

⚠️  ATTENTION: $TESTS_FAILED backup verification tests failed.
Review the backup system immediately to ensure data protection.

"
fi

EMAIL_BODY="$EMAIL_BODY

This weekly verification ensures backup systems are functional
for disaster recovery and SOC 2 compliance requirements.

View detailed metrics in your Datadog dashboard.
Check logs: /var/log/backups/backup-verify.log"

echo "$EMAIL_BODY" | mail -s "$EMAIL_SUBJECT" "$ADMIN_EMAIL"

if [ "$TESTS_FAILED" -gt 0 ]; then
    log_message "Verification completed with $TESTS_FAILED failures"
    exit 1
else
    log_message "Verification completed successfully - all tests passed"
    exit 0
fi