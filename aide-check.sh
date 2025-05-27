#!/bin/bash
set -euo pipefail
umask 077

# Load configuration files following established pattern
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/aide-check.conf

# Generate timestamped filenames for audit trail
DATE_STAMP=$(date +%Y%m%d)
SCAN_LOG="${REPORT_DIR}/scan-${DATE_STAMP}.log"
REPORT_FILE="${REPORT_DIR}/report-${DATE_STAMP}.txt"
TEMP_FILE="/tmp/aide-${DATE_STAMP}.tmp"

# Log scan initiation to syslog for Grafana Cloud integration
logger -p daemon.notice "AIDE INTEGRITY CHECK: Starting file integrity monitoring scan"

# Ensure required directories exist with proper permissions
if [ ! -d "$REPORT_DIR" ]; then
    logger -p daemon.error "AIDE INTEGRITY CHECK: Report directory missing - integrity monitoring may be compromised"
    echo "CRITICAL: AIDE report directory missing at $REPORT_DIR" | mail -s "[SECURITY CRITICAL] AIDE reporting failure - $(hostname)" "$ADMIN_EMAIL"
    exit 1
fi

if [ ! -d "$DB_ARCHIVE" ]; then
    mkdir -p "$DB_ARCHIVE"
    chmod 750 "$DB_ARCHIVE"
    logger -p daemon.notice "AIDE INTEGRITY CHECK: Created database archive directory at $DB_ARCHIVE"
fi

# Verify AIDE installation and configuration
if [ ! -x "/usr/bin/aide" ]; then
    logger -p daemon.error "AIDE INTEGRITY CHECK: AIDE binary not found or not executable"
    echo "CRITICAL: AIDE not properly installed" | mail -s "[SECURITY CRITICAL] AIDE installation failure - $(hostname)" "$ADMIN_EMAIL"
    exit 1
fi

if [ ! -f "/etc/aide/aide.conf" ]; then
    logger -p daemon.error "AIDE INTEGRITY CHECK: AIDE configuration file missing"
    echo "CRITICAL: AIDE configuration missing at /etc/aide/aide.conf" | mail -s "[SECURITY CRITICAL] AIDE configuration failure - $(hostname)" "$ADMIN_EMAIL"
    exit 1
fi

# Verify AIDE database exists and is readable
if [ ! -f "/var/lib/aide/aide.db" ]; then
    logger -p daemon.error "AIDE INTEGRITY CHECK: AIDE database missing - cannot perform integrity check"
    echo "CRITICAL: AIDE database missing - integrity monitoring disabled" | mail -s "[SECURITY CRITICAL] AIDE database missing - $(hostname)" "$ADMIN_EMAIL"
    exit 1
fi

# Check database age (warn if older than 14 days)
DB_AGE=$(stat -c %Y "/var/lib/aide/aide.db" 2>/dev/null || echo 0)
CURRENT_TIME=$(date +%s)
DB_AGE_DAYS=$(( (CURRENT_TIME - DB_AGE) / 86400 ))

# Initialize comprehensive report
{
    echo "AIDE DAILY INTEGRITY CHECK REPORT"
    echo "=================================="
    echo "Generated: $(date)"
    echo "Host: $(hostname)"
    echo "Database age: $DB_AGE_DAYS days"
    echo "Configuration: /etc/aide/aide.conf"
    echo ""
} > "$REPORT_FILE"

# Warn about stale database
if [ "$DB_AGE_DAYS" -gt 14 ]; then
    logger -p daemon.warning "AIDE INTEGRITY CHECK: Database is $DB_AGE_DAYS days old - integrity baseline may be outdated"
    {
        echo "WARNING: Database Age"
        echo "===================="
        echo "AIDE database is $DB_AGE_DAYS days old."
        echo "Consider updating the baseline if this age is unexpected."
        echo "Weekly automatic updates occur on Sundays."
        echo ""
    } >> "$REPORT_FILE"
fi

# Execute comprehensive AIDE integrity check
logger -p daemon.info "AIDE INTEGRITY CHECK: Executing file integrity scan"
{
    echo "INTEGRITY SCAN EXECUTION"
    echo "======================="
    echo "Scan started: $(date)"
    echo ""
} >> "$REPORT_FILE"

# Run AIDE check and capture detailed output
if /usr/bin/aide --check --config=/etc/aide/aide.conf > "$TEMP_FILE" 2>&1; then
    AIDE_EXIT_CODE=0
    logger -p daemon.info "AIDE INTEGRITY CHECK: Scan completed successfully"
else
    AIDE_EXIT_CODE=$?
    if [ "$AIDE_EXIT_CODE" -eq 1 ]; then
        # Exit code 1 means changes were detected (normal for AIDE)
        logger -p daemon.info "AIDE INTEGRITY CHECK: File changes detected during scan"
    else
        # Other exit codes indicate actual errors
        logger -p daemon.error "AIDE INTEGRITY CHECK: Scan failed with exit code $AIDE_EXIT_CODE"
        {
            echo "SCAN ERROR"
            echo "=========="
            echo "AIDE scan failed with exit code: $AIDE_EXIT_CODE"
            echo "This may indicate database corruption or configuration issues."
            echo ""
        } >> "$REPORT_FILE"
    fi
fi

# Process and analyze scan results
if [ -f "$TEMP_FILE" ]; then
    # Count different types of changes
    ADDED_FILES=$(grep -c "^f++" "$TEMP_FILE" 2>/dev/null || echo 0)
    REMOVED_FILES=$(grep -c "^f--" "$TEMP_FILE" 2>/dev/null || echo 0)
    CHANGED_FILES=$(grep -c "^f\.\." "$TEMP_FILE" 2>/dev/null || echo 0)

    # Detect critical path changes with more comprehensive patterns
    CRITICAL_ETC_CHANGES=$(grep -cE '^f[+\.-].*(/etc/.*:|/etc/.* )' "$TEMP_FILE" 2>/dev/null || echo 0)
    CRITICAL_BOOT_CHANGES=$(grep -cE '^f[+\.-].*(/boot/.*:|/boot/.* )' "$TEMP_FILE" 2>/dev/null || echo 0)
    CRITICAL_BIN_CHANGES=$(grep -cE '^f[+\.-].*(/usr/local/bin/.*:|/usr/local/bin/.* )' "$TEMP_FILE" 2>/dev/null || echo 0)

    TOTAL_CHANGES=$((ADDED_FILES + REMOVED_FILES + CHANGED_FILES))
    CRITICAL_CHANGES=$((CRITICAL_ETC_CHANGES + CRITICAL_BOOT_CHANGES + CRITICAL_BIN_CHANGES))

    # Generate comprehensive summary
    {
        echo "SCAN SUMMARY STATISTICS"
        echo "======================"
        echo "Files added: $ADDED_FILES"
        echo "Files removed: $REMOVED_FILES"
        echo "Files changed: $CHANGED_FILES"
        echo "Total changes: $TOTAL_CHANGES"
        echo ""
        echo "CRITICAL SYSTEM CHANGES"
        echo "======================"
        echo "Configuration files (/etc): $CRITICAL_ETC_CHANGES"
        echo "Boot files (/boot): $CRITICAL_BOOT_CHANGES"
        echo "Local binaries (/usr/local/bin): $CRITICAL_BIN_CHANGES"
        echo "Total critical changes: $CRITICAL_CHANGES"
        echo ""
    } >> "$REPORT_FILE"

    # Detailed analysis sections for significant changes
    if [ "$CRITICAL_CHANGES" -gt 0 ]; then
        {
            echo "CRITICAL CHANGES ANALYSIS"
            echo "========================"

            if [ "$CRITICAL_ETC_CHANGES" -gt 0 ]; then
                echo "Configuration file changes in /etc:"
                grep -E '^f[+\.-].*(/etc/.*:|/etc/.* )' "$TEMP_FILE" | head -10 | sed 's/^/  /' || echo "  No details available"
                if [ "$CRITICAL_ETC_CHANGES" -gt 10 ]; then
                    echo "  ... and $((CRITICAL_ETC_CHANGES - 10)) more configuration changes"
                fi
                echo ""
            fi

            if [ "$CRITICAL_BOOT_CHANGES" -gt 0 ]; then
                echo "Boot file changes in /boot:"
                grep -E '^f[+\.-].*(/boot/.*:|/boot/.* )' "$TEMP_FILE" | head -5 | sed 's/^/  /' || echo "  No details available"
                echo ""
            fi

            if [ "$CRITICAL_BIN_CHANGES" -gt 0 ]; then
                echo "Local binary changes in /usr/local/bin:"
                grep -E '^f[+\.-].*(/usr/local/bin/.*:|/usr/local/bin/.* )' "$TEMP_FILE" | head -5 | sed 's/^/  /' || echo "  No details available"
                echo ""
            fi
        } >> "$REPORT_FILE"
    fi

    # Include full scan output for forensic analysis
    {
        echo "DETAILED SCAN OUTPUT"
        echo "==================="
        echo "Complete AIDE scan results (first 100 lines):"
        echo ""
    } >> "$REPORT_FILE"

    head -100 "$TEMP_FILE" >> "$REPORT_FILE" 2>/dev/null || echo "No scan output available" >> "$REPORT_FILE"

    if [ "$(wc -l < "$TEMP_FILE" 2>/dev/null || echo 0)" -gt 100 ]; then
        echo "" >> "$REPORT_FILE"
        echo "(Output truncated - see full scan log: $SCAN_LOG)" >> "$REPORT_FILE"
    fi

    # Copy full output to scan log
    cp "$TEMP_FILE" "$SCAN_LOG" 2>/dev/null || touch "$SCAN_LOG"

else
    logger -p daemon.error "AIDE INTEGRITY CHECK: No scan output generated"
    {
        echo "SCAN OUTPUT ERROR"
        echo "================"
        echo "No scan output was generated. This indicates a serious"
        echo "problem with AIDE configuration or database integrity."
        echo ""
    } >> "$REPORT_FILE"
    AIDE_EXIT_CODE=2
fi

# Handle weekly database update (Sundays)
if [ "$(date +%u)" -eq 7 ]; then
    logger -p daemon.info "AIDE INTEGRITY CHECK: Performing weekly database update"
    {
        echo "WEEKLY DATABASE UPDATE"
        echo "====================="
        echo "Performing scheduled database update on $(date)"
        echo ""
    } >> "$REPORT_FILE"

    # Archive current database before update
    if cp /var/lib/aide/aide.db "$DB_ARCHIVE/aide.db_$DATE_STAMP" 2>/dev/null; then
        logger -p daemon.notice "AIDE INTEGRITY CHECK: Database archived to $DB_ARCHIVE/aide.db_$DATE_STAMP"
        echo "Current database archived to: $DB_ARCHIVE/aide.db_$DATE_STAMP" >> "$REPORT_FILE"
    else
        logger -p daemon.error "AIDE INTEGRITY CHECK: Failed to archive current database"
        echo "ERROR: Failed to archive current database" >> "$REPORT_FILE"
    fi

    # Generate new database
    if /usr/bin/aide --update --config=/etc/aide/aide.conf >/dev/null 2>&1; then
        # Replace current database with new one
        if cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db 2>/dev/null; then
            logger -p daemon.notice "AIDE INTEGRITY CHECK: Database successfully updated"
            echo "Database update completed successfully" >> "$REPORT_FILE"
            rm -f /var/lib/aide/aide.db.new 2>/dev/null || true
        else
            logger -p daemon.error "AIDE INTEGRITY CHECK: Failed to replace database after update"
            echo "ERROR: Failed to replace database after update" >> "$REPORT_FILE"
        fi
    else
        logger -p daemon.error "AIDE INTEGRITY CHECK: Database update failed"
        echo "ERROR: Database update failed" >> "$REPORT_FILE"
    fi
    echo "" >> "$REPORT_FILE"
fi

# Clean up old evidence (retain for SOC 2 compliance period)
{
    echo "MAINTENANCE ACTIVITIES"
    echo "===================="

    # Clean old reports (keep 1 year for SOC 2)
    CLEANED_REPORTS=$(find "$REPORT_DIR" -type f -mtime +365 -delete -print 2>/dev/null | wc -l || echo 0)
    if [ "$CLEANED_REPORTS" -gt 0 ]; then
        echo "Cleaned $CLEANED_REPORTS old report files (>365 days)"
        logger -p daemon.info "AIDE INTEGRITY CHECK: Cleaned $CLEANED_REPORTS old report files"
    fi

    # Clean old database archives (keep 1 year for SOC 2)
    CLEANED_ARCHIVES=$(find "$DB_ARCHIVE" -type f -mtime +365 -delete -print 2>/dev/null | wc -l || echo 0)
    if [ "$CLEANED_ARCHIVES" -gt 0 ]; then
        echo "Cleaned $CLEANED_ARCHIVES old database archives (>365 days)"
        logger -p daemon.info "AIDE INTEGRITY CHECK: Cleaned $CLEANED_ARCHIVES old database archives"
    fi

    echo ""
} >> "$REPORT_FILE"

# Append report metadata for audit trail
{
    echo "REPORT INFORMATION"
    echo "=================="
    echo "Report generated by: $(basename "$0")"
    echo "Scan log location: $SCAN_LOG"
    echo "Report location: $REPORT_FILE"
    echo "Compressed archive: ${REPORT_FILE}.gz"
    echo "Database location: /var/lib/aide/aide.db"
    echo "Archive directory: $DB_ARCHIVE"
} >> "$REPORT_FILE"

# Determine alert severity and send appropriate notifications
if [ "$CRITICAL_CHANGES" -gt 0 ]; then
    # Critical changes to system files require immediate attention
    logger -p daemon.crit "AIDE INTEGRITY CHECK: CRITICAL - $CRITICAL_CHANGES critical file changes detected requiring immediate review"
    mail -s "[SECURITY CRITICAL] AIDE Critical Changes - $CRITICAL_CHANGES changes in system files - $(hostname) - $(date +%F)" "$ADMIN_EMAIL" < "$REPORT_FILE"
elif [ "$TOTAL_CHANGES" -gt 20 ]; then
    # Large number of changes may indicate significant system activity
    logger -p daemon.warning "AIDE INTEGRITY CHECK: WARNING - $TOTAL_CHANGES file changes detected requiring review"
    mail -s "[SECURITY WARNING] AIDE File Changes - $TOTAL_CHANGES changes detected - $(hostname) - $(date +%F)" "$ADMIN_EMAIL" < "$REPORT_FILE"
elif [ "$TOTAL_CHANGES" -gt 0 ]; then
    # Normal file changes for informational purposes
    logger -p daemon.notice "AIDE INTEGRITY CHECK: $TOTAL_CHANGES file changes detected"
    mail -s "[SECURITY] AIDE File Changes - $TOTAL_CHANGES changes detected - $(hostname) - $(date +%F)" "$ADMIN_EMAIL" < "$REPORT_FILE"
elif [ "$AIDE_EXIT_CODE" -ne 0 ]; then
    # Scan errors need attention
    logger -p daemon.error "AIDE INTEGRITY CHECK: ERROR - Scan completed with errors (exit code $AIDE_EXIT_CODE)"
    mail -s "[SECURITY ERROR] AIDE Scan Error - Exit code $AIDE_EXIT_CODE - $(hostname) - $(date +%F)" "$ADMIN_EMAIL" < "$REPORT_FILE"
else
    # Clean scan for compliance documentation
    logger -p daemon.notice "AIDE INTEGRITY CHECK: Clean scan completed - no file changes detected"
    mail -s "[SECURITY] AIDE Integrity Check - No changes detected - $(hostname) - $(date +%F)" "$ADMIN_EMAIL" < "$REPORT_FILE"
fi

# Compress report for efficient storage
if [ -f "$REPORT_FILE" ]; then
    gzip -9 "$REPORT_FILE"

    # Create convenience symlinks to latest results
    ln -sf "${REPORT_FILE}.gz" "${REPORT_DIR}/latest-integrity-report.gz" 2>/dev/null || true
fi

# Create convenience symlink to latest scan log
if [ -f "$SCAN_LOG" ]; then
    ln -sf "$SCAN_LOG" "${REPORT_DIR}/latest-integrity-scan.log" 2>/dev/null || true
fi

# Clean up temporary files securely
[ -f "$TEMP_FILE" ] && shred -zu "$TEMP_FILE" 2>/dev/null || rm -f "$TEMP_FILE"

# Log successful completion for audit trail
logger -p daemon.notice "AIDE INTEGRITY CHECK: Daily integrity check completed - $TOTAL_CHANGES changes detected, $CRITICAL_CHANGES critical"

exit 0