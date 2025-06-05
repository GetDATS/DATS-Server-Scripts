#!/bin/bash
set -euo pipefail

# AIDE file integrity checker with Datadog integration
# Focuses on detecting critical system file changes with clear alerting

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/aide-check.conf

LOG_FILE="$REPORT_DIR/aide-check.log"

# Datadog-friendly logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    # Use 'aide' tag for consistent syslog routing to Datadog
    logger -t aide "$1"
}

# Check if AIDE is properly set up
if [ ! -f "/var/lib/aide/aide.db" ]; then
    log_message "ERROR: AIDE database missing - run 'aide --init' first"
    echo "AIDE database is missing on $(hostname). Run 'sudo aide --init' to initialize." | mail -s "[SECURITY ERROR] AIDE Database Missing" "$ADMIN_EMAIL"
    exit 1
fi

log_message "Starting AIDE file integrity check"

# Run AIDE check
AIDE_RESULT=$(mktemp)
if aide --check --config=/etc/aide/aide.conf > "$AIDE_RESULT" 2>&1; then
    AIDE_STATUS="clean"
    CHANGES_FOUND=0
else
    AIDE_EXIT_CODE=$?
    if [ "$AIDE_EXIT_CODE" -eq 1 ]; then
        # Exit code 1 means changes were detected (normal)
        AIDE_STATUS="changes"
        CHANGES_FOUND=1
    else
        # Other exit codes indicate errors
        AIDE_STATUS="error"
        CHANGES_FOUND=0
    fi
fi

# Count total changes and critical changes
TOTAL_CHANGES=$(grep -c "^f[+\.-]" "$AIDE_RESULT" 2>/dev/null || echo "0")
CRITICAL_CHANGES=$(grep -cE "^f[+\.-].*/etc/|^f[+\.-].*/boot/|^f[+\.-].*/usr/local/bin/" "$AIDE_RESULT" 2>/dev/null || echo "0")

# Log structured metrics for Datadog
logger -t aide "INTEGRITY_CHECK: total_changes=$TOTAL_CHANGES critical_changes=$CRITICAL_CHANGES status=$AIDE_STATUS"

# Handle results based on what we found
if [ "$CRITICAL_CHANGES" -gt 0 ]; then
    log_message "CRITICAL: $CRITICAL_CHANGES critical system files changed"
    {
        echo "AIDE detected $CRITICAL_CHANGES critical system file changes on $(hostname)"
        echo "Total changes: $TOTAL_CHANGES"
        echo ""
        echo "Critical changes in system directories:"
        grep -E "^f[+\.-].*/etc/|^f[+\.-].*/boot/|^f[+\.-].*/usr/local/bin/" "$AIDE_RESULT" | head -20
        if [ "$CRITICAL_CHANGES" -gt 20 ]; then
            echo ""
            echo "(Showing first 20 of $CRITICAL_CHANGES critical changes)"
        fi
        echo ""
        echo "View detailed analysis and trends in your Datadog dashboard."
        echo ""
        echo "Full AIDE output:"
        cat "$AIDE_RESULT"
    } | mail -s "[SECURITY CRITICAL] AIDE - $CRITICAL_CHANGES critical system changes - $(hostname)" "$ADMIN_EMAIL"

elif [ "$TOTAL_CHANGES" -gt 0 ]; then
    log_message "Changes detected: $TOTAL_CHANGES files changed (no critical system files)"
    {
        echo "AIDE detected $TOTAL_CHANGES file changes on $(hostname)"
        echo "No critical system files were affected."
        echo ""
        echo "Changed files:"
        head -20 "$AIDE_RESULT"
        if [ "$TOTAL_CHANGES" -gt 20 ]; then
            echo ""
            echo "(Showing first 20 of $TOTAL_CHANGES changes)"
        fi
        echo ""
        echo "View detailed analysis in your Datadog dashboard."
    } | mail -s "[AIDE] File Changes - $TOTAL_CHANGES changes - $(hostname)" "$ADMIN_EMAIL"

elif [ "$AIDE_STATUS" = "error" ]; then
    log_message "ERROR: AIDE check failed with exit code $AIDE_EXIT_CODE"
    {
        echo "AIDE integrity check failed on $(hostname)"
        echo "Exit code: $AIDE_EXIT_CODE"
        echo ""
        echo "Error output:"
        cat "$AIDE_RESULT"
    } | mail -s "[SECURITY ERROR] AIDE Check Failed - $(hostname)" "$ADMIN_EMAIL"

else
    log_message "Integrity check completed - no changes detected"
    {
        echo "AIDE integrity check completed successfully on $(hostname)"
        echo ""
        echo "Result: No file changes detected"
        echo "Database age: $(stat -c %Y /var/lib/aide/aide.db | xargs -I {} date -d @{} '+%Y-%m-%d')"
        echo ""
        echo "This is a routine integrity check confirmation."
        echo "View historical trends in your Datadog dashboard."
    } | mail -s "[AIDE] Integrity Check - Clean - $(hostname)" "$ADMIN_EMAIL"
fi

# Update database weekly (Sundays)
if [ "$(date +%u)" -eq 7 ] && [ "$AIDE_STATUS" = "clean" ]; then
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
    else
        log_message "ERROR: Database update failed"
    fi
fi

# Clean up
rm -f "$AIDE_RESULT"

log_message "AIDE check completed"