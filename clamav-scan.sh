#!/bin/bash
set -euo pipefail
umask 077

# Load configuration files following established pattern
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/clamav-scan.conf

# Generate timestamped filenames for audit trail
DATE_STAMP=$(date +%Y%m%d)
SCAN_LOG="${LOG_DIR}/scan-${DATE_STAMP}.log"
REPORT_FILE="${LOG_DIR}/report-${DATE_STAMP}.txt"
TEMP_FILE="/tmp/clamav-${DATE_STAMP}.tmp"

# Log scan initiation to syslog for Grafana Cloud integration
logger -p daemon.notice "CLAMAV SCAN: Starting comprehensive malware scan"

# Ensure log directory exists with proper permissions
if [ ! -d "$LOG_DIR" ]; then
    logger -p daemon.error "CLAMAV SCAN: Log directory missing - scanning may be compromised"
    echo "CRITICAL: ClamAV log directory missing at $LOG_DIR" | mail -s "[SECURITY CRITICAL] ClamAV logging failure - $(hostname)" "$ADMIN_EMAIL"
    exit 1
fi

# Ensure quarantine directory exists with proper permissions
if [ ! -d "$QUARANTINE_DIR" ]; then
    mkdir -p "$QUARANTINE_DIR"
    chown clamav:clamav "$QUARANTINE_DIR"
    chmod 750 "$QUARANTINE_DIR"
    logger -p daemon.notice "CLAMAV SCAN: Created quarantine directory at $QUARANTINE_DIR"
fi

# Initialize scan report with header information
{
    echo "CLAMAV DAILY MALWARE SCAN REPORT"
    echo "================================="
    echo "Generated: $(date)"
    echo "Host: $(hostname)"
    echo "Scan Period: $(date +%F)"
    echo ""
} > "$REPORT_FILE"

# Verify ClamAV daemon is running and database is current
if ! systemctl is-active --quiet clamav-daemon; then
    logger -p daemon.warning "CLAMAV SCAN: ClamAV daemon not running - attempting to start"
    echo "WARNING: ClamAV daemon not running - attempting to start..." >> "$REPORT_FILE"

    if systemctl start clamav-daemon; then
        logger -p daemon.notice "CLAMAV SCAN: Successfully started ClamAV daemon"
        echo "SUCCESS: ClamAV daemon started successfully" >> "$REPORT_FILE"
        sleep 10  # Allow daemon to fully initialize
    else
        logger -p daemon.error "CLAMAV SCAN: Failed to start ClamAV daemon - scan aborted"
        echo "CRITICAL: Failed to start ClamAV daemon - scan aborted" >> "$REPORT_FILE"
        mail -s "[SECURITY CRITICAL] ClamAV daemon failed to start - $(hostname)" "$ADMIN_EMAIL" < "$REPORT_FILE"
        exit 1
    fi
fi

# Check database freshness (warn if older than 7 days)
DB_AGE=$(find /var/lib/clamav -name "*.cvd" -o -name "*.cld" | xargs stat -c %Y | sort -n | tail -1)
CURRENT_TIME=$(date +%s)
DB_AGE_DAYS=$(( (CURRENT_TIME - DB_AGE) / 86400 ))

if [ "$DB_AGE_DAYS" -gt 7 ]; then
    logger -p daemon.warning "CLAMAV SCAN: Virus database is $DB_AGE_DAYS days old - may miss recent threats"
    echo "WARNING: Virus database is $DB_AGE_DAYS days old - consider updating" >> "$REPORT_FILE"
fi

# Initialize scan statistics
TOTAL_FILES=0
INFECTED_FILES=0
SCAN_ERRORS=0
DIRECTORIES_SCANNED=0

# Begin comprehensive scanning process
{
    echo "SCAN EXECUTION LOG"
    echo "=================="
    echo "Scan started: $(date)"
    echo ""
} >> "$REPORT_FILE"

# Perform scans on each configured directory
for SCAN_DIR in "${SCAN_DIRS[@]}"; do
    if [ ! -d "$SCAN_DIR" ]; then
        logger -p daemon.warning "CLAMAV SCAN: Configured scan directory $SCAN_DIR does not exist - skipping"
        echo "WARNING: Directory $SCAN_DIR does not exist - skipping" >> "$REPORT_FILE"
        continue
    fi

    echo "Scanning directory: $SCAN_DIR" >> "$REPORT_FILE"
    logger -p daemon.info "CLAMAV SCAN: Scanning directory $SCAN_DIR"

    # Execute scan with comprehensive options and capture detailed output
    if clamdscan --multiscan --fdpass --infected --move="$QUARANTINE_DIR" --log="$TEMP_FILE" "$SCAN_DIR" 2>&1; then
        SCAN_RESULT=$?
    else
        SCAN_RESULT=$?
    fi

    # Process scan results for this directory
    if [ -f "$TEMP_FILE" ]; then
        # Count files scanned in this directory
        DIR_FILES=$(grep -c "OK$\|FOUND$\|ERROR$" "$TEMP_FILE" 2>/dev/null || echo 0)
        DIR_INFECTED=$(grep -c "FOUND$" "$TEMP_FILE" 2>/dev/null || echo 0)
        DIR_ERRORS=$(grep -c "ERROR$" "$TEMP_FILE" 2>/dev/null || echo 0)

        TOTAL_FILES=$((TOTAL_FILES + DIR_FILES))
        INFECTED_FILES=$((INFECTED_FILES + DIR_INFECTED))
        SCAN_ERRORS=$((SCAN_ERRORS + DIR_ERRORS))
        DIRECTORIES_SCANNED=$((DIRECTORIES_SCANNED + 1))

        # Append detailed results to report
        echo "  Files scanned: $DIR_FILES" >> "$REPORT_FILE"
        echo "  Threats found: $DIR_INFECTED" >> "$REPORT_FILE"
        echo "  Scan errors: $DIR_ERRORS" >> "$REPORT_FILE"

        # Include any infected files in report
        if [ "$DIR_INFECTED" -gt 0 ]; then
            echo "  Infected files found:" >> "$REPORT_FILE"
            grep "FOUND$" "$TEMP_FILE" | sed 's/^/    /' >> "$REPORT_FILE" 2>/dev/null || true
        fi

        # Include any scan errors in report
        if [ "$DIR_ERRORS" -gt 0 ]; then
            echo "  Scan errors encountered:" >> "$REPORT_FILE"
            grep "ERROR$" "$TEMP_FILE" | sed 's/^/    /' >> "$REPORT_FILE" 2>/dev/null || true
        fi

        echo "" >> "$REPORT_FILE"

        # Clean up temporary file
        rm -f "$TEMP_FILE"
    else
        logger -p daemon.error "CLAMAV SCAN: No scan output generated for directory $SCAN_DIR"
        echo "  ERROR: No scan output generated" >> "$REPORT_FILE"
        SCAN_ERRORS=$((SCAN_ERRORS + 1))
    fi
done

# Generate comprehensive summary statistics
{
    echo "SCAN SUMMARY STATISTICS"
    echo "======================"
    echo "Directories scanned: $DIRECTORIES_SCANNED"
    echo "Total files scanned: $TOTAL_FILES"
    echo "Infected files found: $INFECTED_FILES"
    echo "Scan errors encountered: $SCAN_ERRORS"
    echo "Scan completed: $(date)"
    echo ""
} >> "$REPORT_FILE"

# Detailed analysis section for threats found
if [ "$INFECTED_FILES" -gt 0 ]; then
    {
        echo "THREAT ANALYSIS"
        echo "==============="
        echo "Files have been moved to quarantine directory: $QUARANTINE_DIR"
        echo "Review quarantined files and determine if they are false positives"
        echo "or legitimate threats requiring further investigation."
        echo ""

        # List quarantined files if any exist
        if [ -d "$QUARANTINE_DIR" ] && [ "$(ls -A "$QUARANTINE_DIR" 2>/dev/null)" ]; then
            echo "Current quarantine contents:"
            ls -la "$QUARANTINE_DIR" | sed 's/^/  /'
        fi
        echo ""
    } >> "$REPORT_FILE"
fi

# Append report metadata for audit trail
{
    echo "REPORT INFORMATION"
    echo "=================="
    echo "Report generated by: $(basename "$0")"
    echo "Scan log location: $SCAN_LOG"
    echo "Report location: $REPORT_FILE"
    echo "Compressed archive: ${REPORT_FILE}.gz"
    echo "Quarantine directory: $QUARANTINE_DIR"
} >> "$REPORT_FILE"

# Calculate threat level for appropriate alerting
SECURITY_CONCERNS=$((INFECTED_FILES + SCAN_ERRORS))

# Send notification based on findings severity
if [ "$INFECTED_FILES" -gt 0 ]; then
    # Critical security threats requiring immediate attention
    logger -p daemon.crit "CLAMAV SCAN: CRITICAL - $INFECTED_FILES malware threats detected requiring immediate review"
    mail -s "[SECURITY CRITICAL] ClamAV Scan - $INFECTED_FILES threats found - $(hostname) - $(date +%F)" "$ADMIN_EMAIL" < "$REPORT_FILE"
elif [ "$SCAN_ERRORS" -gt 5 ]; then
    # Multiple scan errors may indicate system issues
    logger -p daemon.error "CLAMAV SCAN: ERROR - $SCAN_ERRORS scan errors detected - system integrity may be compromised"
    mail -s "[SECURITY ERROR] ClamAV Scan - $SCAN_ERRORS scan errors - $(hostname) - $(date +%F)" "$ADMIN_EMAIL" < "$REPORT_FILE"
elif [ "$SCAN_ERRORS" -gt 0 ]; then
    # Minor scan errors for awareness
    logger -p daemon.warning "CLAMAV SCAN: WARNING - $SCAN_ERRORS scan errors detected"
    mail -s "[SECURITY WARNING] ClamAV Scan - $SCAN_ERRORS scan errors - $(hostname) - $(date +%F)" "$ADMIN_EMAIL" < "$REPORT_FILE"
else
    # Clean scan for compliance records
    logger -p daemon.notice "CLAMAV SCAN: Clean scan completed - $TOTAL_FILES files scanned, no threats detected"
    mail -s "[SECURITY] ClamAV Scan - Clean - $TOTAL_FILES files scanned - $(hostname) - $(date +%F)" "$ADMIN_EMAIL" < "$REPORT_FILE"
fi

# Compress report for efficient storage
if [ -f "$REPORT_FILE" ]; then
    gzip -9 "$REPORT_FILE"

    # Create convenience symlinks to latest results
    ln -sf "${REPORT_FILE}.gz" "${LOG_DIR}/latest-scan-report.gz" 2>/dev/null || true
fi

# Create convenience symlink to latest scan log if it exists
if [ -f "$SCAN_LOG" ]; then
    ln -sf "$SCAN_LOG" "${LOG_DIR}/latest-scan.log" 2>/dev/null || true
fi

# Clean up any remaining temporary files securely
[ -f "$TEMP_FILE" ] && shred -zu "$TEMP_FILE" 2>/dev/null || rm -f "$TEMP_FILE"

# Log successful completion for audit trail
logger -p daemon.notice "CLAMAV SCAN: Daily scan completed successfully - $TOTAL_FILES files scanned, $INFECTED_FILES threats found, $SCAN_ERRORS errors"

exit 0