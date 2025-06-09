#!/bin/bash
set -euo pipefail

# AIDE file integrity checker with monitoring integration
# Focuses on detecting critical system file changes with clear alerting

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/aide-check.conf

LOG_FILE="$LOG_DIR/aide-check.log"

# Structured logging function for monitoring integration
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    # Use consistent tag for syslog routing
    logger -t soc2-aide "$1"
}

# Log structured metrics for monitoring
log_metrics() {
    local total_changes=$1
    local critical_changes=$2
    local status=$3
    local operation_duration=${4:-0}

    # Structured log entry for monitoring system
    logger -t soc2-aide "OPERATION_COMPLETE: service=aide operation=integrity_check total_changes=$total_changes critical_changes=$critical_changes status=$status duration_seconds=$operation_duration"
}

# Check if AIDE is properly set up
if [ ! -f "/var/lib/aide/aide.db" ]; then
    log_message "ERROR: AIDE database missing - run 'aide --init' first"
    logger -t soc2-aide "OPERATION_COMPLETE: service=aide operation=integrity_check status=$STATUS_ERROR error=database_missing"
    echo "AIDE database is missing on $(hostname). Run 'sudo aide --init' to initialize." | mail -s "[SECURITY ERROR] AIDE Database Missing" -r "$AIDE_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1
fi

log_message "Starting AIDE file integrity check"
CHECK_START=$(date +%s)

# Run AIDE check
AIDE_RESULT=$(mktemp)
if aide --check --config=/etc/aide/aide.conf > "$AIDE_RESULT" 2>&1; then
    AIDE_STATUS="$STATUS_SUCCESS"
    CHANGES_FOUND=0
else
    AIDE_EXIT_CODE=$?
    if [ "$AIDE_EXIT_CODE" -eq 1 ]; then
        # Exit code 1 means changes were detected (normal)
        AIDE_STATUS="$STATUS_WARNING"
        CHANGES_FOUND=1
    else
        # Other exit codes indicate errors
        AIDE_STATUS="$STATUS_ERROR"
        CHANGES_FOUND=0
    fi
fi

CHECK_END=$(date +%s)
CHECK_DURATION=$((CHECK_END - CHECK_START))

# Count total changes and critical changes
TOTAL_CHANGES=$(grep -c "^f[+\.-]" "$AIDE_RESULT" 2>/dev/null || echo "0")
CRITICAL_CHANGES=$(grep -cE "^f[+\.-].*/etc/|^f[+\.-].*/boot/|^f[+\.-].*/usr/local/bin/" "$AIDE_RESULT" 2>/dev/null || echo "0")

# Log structured metrics for monitoring
log_metrics "$TOTAL_CHANGES" "$CRITICAL_CHANGES" "$AIDE_STATUS" "$CHECK_DURATION"

# Handle results based on what we found
if [ "$CRITICAL_CHANGES" -gt 0 ]; then
    log_message "CRITICAL: $CRITICAL_CHANGES critical system files changed"

    # Log detailed changes to secure log for investigation
    echo "=== CRITICAL CHANGES $(date) ===" >> "$LOG_FILE"
    grep -E "^f[+\.-].*/etc/|^f[+\.-].*/boot/|^f[+\.-].*/usr/local/bin/" "$AIDE_RESULT" >> "$LOG_FILE"
    echo "=== END CRITICAL CHANGES ===" >> "$LOG_FILE"

    # Log security events for monitoring
    logger -t soc2-security "INTEGRITY_VIOLATION: service=aide critical_changes=$CRITICAL_CHANGES total_changes=$TOTAL_CHANGES severity=critical"

    {
        echo "AIDE detected $CRITICAL_CHANGES critical system file changes on $(hostname)"
        echo ""
        echo "Change Summary:"
        echo "- Critical changes: $CRITICAL_CHANGES (requires immediate attention)"
        echo "- Total changes: $TOTAL_CHANGES"
        echo "- Check duration: ${CHECK_DURATION} seconds"
        echo "- Status: REQUIRES IMMEDIATE INVESTIGATION"
        echo ""
        echo "Security Actions Required:"
        echo "1. Review detailed change log: $LOG_FILE"
        echo "2. Verify changes are authorized"
        echo "3. Investigate potential security incidents"
        echo ""
        echo "Critical system directories affected - detailed analysis required."
        echo "Change details have been logged securely for investigation."
    } | mail -s "[SECURITY CRITICAL] AIDE - $CRITICAL_CHANGES critical system changes - $(hostname)" -r "$AIDE_EMAIL_FROM" "$ADMIN_EMAIL"

elif [ "$TOTAL_CHANGES" -gt 0 ]; then
    log_message "Changes detected: $TOTAL_CHANGES files changed (no critical system files)"

    # Log non-critical changes to secure log
    echo "=== NON-CRITICAL CHANGES $(date) ===" >> "$LOG_FILE"
    head -50 "$AIDE_RESULT" >> "$LOG_FILE"
    echo "=== END NON-CRITICAL CHANGES ===" >> "$LOG_FILE"

    # Determine change scale for reporting
    if [ "$TOTAL_CHANGES" -gt 100 ]; then
        CHANGE_SCALE="large"
    elif [ "$TOTAL_CHANGES" -gt 20 ]; then
        CHANGE_SCALE="medium"
    else
        CHANGE_SCALE="small"
    fi

    {
        echo "AIDE detected $TOTAL_CHANGES file changes on $(hostname)"
        echo ""
        echo "Change Summary:"
        echo "- Total changes: $CHANGE_SCALE scale ($TOTAL_CHANGES files)"
        echo "- Critical changes: 0 (no system files affected)"
        echo "- Check duration: ${CHECK_DURATION} seconds"
        echo "- Status: Normal operational changes"
        echo ""
        echo "No critical system files were affected."
        echo "Detailed change analysis available in secure logs."
        echo "This appears to be normal operational file activity."
    } | mail -s "[AIDE] File Changes - $TOTAL_CHANGES changes - $(hostname)" -r "$AIDE_EMAIL_FROM" "$ADMIN_EMAIL"

elif [ "$AIDE_STATUS" = "$STATUS_ERROR" ]; then
    log_message "ERROR: AIDE check failed with exit code $AIDE_EXIT_CODE"

    # Log error details to secure log
    echo "=== AIDE ERROR $(date) ===" >> "$LOG_FILE"
    cat "$AIDE_RESULT" >> "$LOG_FILE"
    echo "=== END AIDE ERROR ===" >> "$LOG_FILE"

    {
        echo "AIDE integrity check failed on $(hostname)"
        echo ""
        echo "Error Summary:"
        echo "- Exit code: $AIDE_EXIT_CODE"
        echo "- Check duration: ${CHECK_DURATION} seconds"
        echo "- Status: System error - integrity checking disabled"
        echo ""
        echo "Security Actions Required:"
        echo "1. Review error details: $LOG_FILE"
        echo "2. Restore AIDE functionality immediately"
        echo "3. Verify system integrity through alternative means"
        echo ""
        echo "File integrity monitoring is currently offline."
    } | mail -s "[SECURITY ERROR] AIDE Check Failed - $(hostname)" -r "$AIDE_EMAIL_FROM" "$ADMIN_EMAIL"

else
    log_message "Integrity check completed - no changes detected"
    {
        echo "AIDE integrity check completed successfully on $(hostname)"
        echo ""
        echo "Check Results:"
        echo "- Status: Clean (no file changes detected)"
        echo "- Files monitored: Active"
        echo "- Check duration: ${CHECK_DURATION} seconds"
        echo "- Database age: $(stat -c %Y /var/lib/aide/aide.db | xargs -I {} date -d @{} '+%Y-%m-%d')"
        echo ""
        echo "This is a routine integrity check confirmation."
        echo "Historical trends available in monitoring dashboard."
    } | mail -s "[AIDE] Integrity Check - Clean - $(hostname)" -r "$AIDE_EMAIL_FROM" "$ADMIN_EMAIL"
fi

# Update database weekly (Sundays)
if [ "$(date +%u)" -eq 7 ] && [ "$AIDE_STATUS" = "$STATUS_SUCCESS" ]; then
    log_message "Performing weekly database update"

    # Create archive directory if it doesn't exist
    mkdir -p "$DB_ARCHIVE"

    # Simple backup before update
    DATE_STAMP=$(date +%Y%m%d)
    if cp /var/lib/aide/aide.db "$DB_ARCHIVE/aide.db_$DATE_STAMP" 2>/dev/null; then
        log_message "Database backed up to $DB_ARCHIVE/aide.db_$DATE_STAMP"
    fi

    # Clean old backups (keep 12 weeks for SOC 2 comfort)
    find "$DB_ARCHIVE" -name "aide.db_*" -mtime +84 -delete 2>/dev/null || true

    # Update database
    if aide --update --config=/etc/aide/aide.conf >/dev/null 2>&1; then
        cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
        rm -f /var/lib/aide/aide.db.new
        log_message "Database updated successfully"
        logger -t soc2-aide "OPERATION_COMPLETE: service=aide operation=database_update status=$STATUS_SUCCESS"
    else
        log_message "ERROR: Database update failed"
        logger -t soc2-aide "OPERATION_COMPLETE: service=aide operation=database_update status=$STATUS_ERROR"
    fi
fi

# Clean up
rm -f "$AIDE_RESULT"

log_message "AIDE check completed"