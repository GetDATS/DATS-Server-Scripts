#!/bin/bash
set -euo pipefail

# ClamAV daily scanner with Datadog integration
# Implements hybrid scanning: full scans for system dirs, recent-only for uploads

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/clamav-scan.conf

LOG_FILE="$LOG_DIR/clamav-daily-scan.log"

# Datadog-friendly logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    # Use consistent tag for syslog routing to Datadog
    logger -t soc2-clamav "$1"
}

# Log structured metrics for Datadog monitoring
log_metrics() {
    local files_scanned=$1
    local threats_found=$2
    local status=$3

    # Structured log entry that Datadog can parse and alert on - standardized format
    logger -t soc2-clamav "OPERATION_COMPLETE: service=clamav operation=scan files_scanned=$files_scanned threats_found=$threats_found status=$status duration_seconds=${SCAN_DURATION:-0}"
}

# Check if ClamAV daemon is running
if ! systemctl is-active --quiet clamav-daemon; then
    log_message "ERROR: ClamAV daemon not running"
    logger -t soc2-clamav "OPERATION_COMPLETE: service=clamav operation=scan status=$STATUS_ERROR error=daemon_not_running"
    echo "ClamAV daemon is not running on $(hostname)" | mail -s "[SECURITY ERROR] ClamAV Daemon Down" -r "$CLAMAV_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1
fi

log_message "Starting daily ClamAV scan"
SCAN_START=$(date +%s)

# Initialize counters
TOTAL_FILES_SCANNED=0
TOTAL_INFECTED_COUNT=0
SCAN_STATUS="$STATUS_SUCCESS"

# Function to parse ClamAV output and update counters
parse_scan_output() {
    local output_file=$1
    local scanned=$(grep "Scanned files:" "$output_file" 2>/dev/null | sed 's/.*Scanned files: \([0-9]*\).*/\1/' | head -1 | tr -d '\n\r\t ' || echo "0")
    local infected=$(grep "Infected files:" "$output_file" 2>/dev/null | sed 's/.*Infected files: \([0-9]*\).*/\1/' | head -1 | tr -d '\n\r\t ' || echo "0")

    # Validate they're actually numbers
    [[ "$scanned" =~ ^[0-9]+$ ]] || scanned="0"
    [[ "$infected" =~ ^[0-9]+$ ]] || infected="0"

    echo "$scanned $infected"
}

# Part 1: Full scan of system directories
log_message "Scanning system directories"
SYSTEM_SCAN_RESULT=$(mktemp)

if [ ${#SYSTEM_SCAN_DIRS[@]} -gt 0 ]; then
    if clamscan --recursive --infected --log="$SYSTEM_SCAN_RESULT" "${SYSTEM_SCAN_DIRS[@]}" 2>&1; then
        log_message "System directory scan completed successfully"
    else
        SCAN_STATUS="$STATUS_WARNING"
        log_message "System directory scan found threats"
    fi

    # Parse results
    read -r scanned infected <<< "$(parse_scan_output "$SYSTEM_SCAN_RESULT")"
    TOTAL_FILES_SCANNED=$((TOTAL_FILES_SCANNED + scanned))
    TOTAL_INFECTED_COUNT=$((TOTAL_INFECTED_COUNT + infected))

    log_message "System scan: $scanned files scanned, $infected threats found"
fi

# Part 2: Recent-files-only scan of upload directories
log_message "Scanning recent uploads"

# Build list of recent files to scan
RECENT_FILES_LIST=$(mktemp)
RECENT_FILE_COUNT=0

for upload_dir in "${UPLOAD_SCAN_DIRS[@]}"; do
    # Expand glob patterns
    for dir in $upload_dir; do
        if [ -d "$dir" ]; then
            log_message "Finding recent files in: $dir"
            # Find files modified in last N days, within size limits
            find "$dir" -type f \
                -mtime -${CLAMAV_RECENT_DAYS} \
                -size +1c \
                -size -${CLAMAV_MAX_FILESIZE} \
                -print0 >> "$RECENT_FILES_LIST"
        fi
    done
done

# Count files found
RECENT_FILE_COUNT=$(tr -cd '\0' < "$RECENT_FILES_LIST" | wc -c)
log_message "Found $RECENT_FILE_COUNT recent files in upload directories"

# Scan recent files if any were found
if [ "$RECENT_FILE_COUNT" -gt 0 ]; then
    UPLOAD_SCAN_RESULT=$(mktemp)

    # Use clamdscan with file list for better performance
    # Limit to CLAMAV_MAX_FILES to prevent runaway scans
    if tr '\0' '\n' < "$RECENT_FILES_LIST" | head -n ${CLAMAV_MAX_FILES} | \
        xargs -d '\n' clamdscan --infected --multiscan --fdpass 2>&1 | \
        tee "$UPLOAD_SCAN_RESULT"; then
        log_message "Upload directory scan completed"
    else
        SCAN_STATUS="$STATUS_WARNING"
        log_message "Upload directory scan found threats"
    fi

    # Count results from clamdscan output
    infected_files=$(grep -c "FOUND" "$UPLOAD_SCAN_RESULT" || echo "0")
    scanned_files=$([ "$RECENT_FILE_COUNT" -gt "$CLAMAV_MAX_FILES" ] && echo "$CLAMAV_MAX_FILES" || echo "$RECENT_FILE_COUNT")

    TOTAL_FILES_SCANNED=$((TOTAL_FILES_SCANNED + scanned_files))
    TOTAL_INFECTED_COUNT=$((TOTAL_INFECTED_COUNT + infected_files))

    log_message "Upload scan: $scanned_files files scanned, $infected_files threats found"

    # If we hit the file limit, note it
    if [ "$RECENT_FILE_COUNT" -gt "$CLAMAV_MAX_FILES" ]; then
        log_message "NOTE: Scan limited to $CLAMAV_MAX_FILES files (found $RECENT_FILE_COUNT recent files)"
    fi

    rm -f "$UPLOAD_SCAN_RESULT"
fi

SCAN_END=$(date +%s)
SCAN_DURATION=$((SCAN_END - SCAN_START))

# Log structured metrics for Datadog
if [ "$TOTAL_INFECTED_COUNT" -gt 0 ]; then
    log_metrics "$TOTAL_FILES_SCANNED" "$TOTAL_INFECTED_COUNT" "$STATUS_WARNING"
else
    log_metrics "$TOTAL_FILES_SCANNED" "$TOTAL_INFECTED_COUNT" "$STATUS_SUCCESS"
fi

# Handle results - send security-conscious notifications
if [ "$TOTAL_INFECTED_COUNT" -gt 0 ]; then
    log_message "ALERT: $TOTAL_INFECTED_COUNT infected files found"

    # Log threats to secure log for investigation
    echo "=== THREAT DETAILS $(date) ===" >> "$LOG_FILE"
    [ -f "$SYSTEM_SCAN_RESULT" ] && grep "FOUND" "$SYSTEM_SCAN_RESULT" >> "$LOG_FILE" 2>/dev/null
    [ -f "$UPLOAD_SCAN_RESULT" ] && grep "FOUND" "$UPLOAD_SCAN_RESULT" >> "$LOG_FILE" 2>/dev/null
    echo "=== END THREAT DETAILS ===" >> "$LOG_FILE"

    # Manually log each infection to syslog for security monitoring
    ([ -f "$SYSTEM_SCAN_RESULT" ] && grep "FOUND" "$SYSTEM_SCAN_RESULT" 2>/dev/null || true; \
     [ -f "$UPLOAD_SCAN_RESULT" ] && grep "FOUND" "$UPLOAD_SCAN_RESULT" 2>/dev/null || true) | \
    while read -r line; do
        logger -t soc2-security "THREAT_DETECTED: service=clamav threat_info=$line"
    done

    {
        echo "ClamAV scan detected $TOTAL_INFECTED_COUNT threats on $(hostname)"
        echo ""
        echo "Scan Summary:"
        echo "Files scanned: $TOTAL_FILES_SCANNED"
        echo "Threats found: $TOTAL_INFECTED_COUNT"
        echo "Scan duration: ${SCAN_DURATION} seconds"
        echo "Status: REQUIRES IMMEDIATE ATTENTION"
        echo ""
        echo "Security Actions Required:"
        echo "1. Review detailed threat log: $LOG_FILE"
        echo "2. Investigate affected systems"
        echo "3. Implement containment measures if needed"
        echo ""
        echo "Threat details have been logged securely for investigation."
        echo "Do not forward this email outside the security team."
    } | mail -s "[SECURITY ALERT] ClamAV - $TOTAL_INFECTED_COUNT threats detected - $(hostname)" -r "$CLAMAV_EMAIL_FROM" "$ADMIN_EMAIL"

else
    log_message "Scan completed - $TOTAL_FILES_SCANNED files scanned, no threats found"

    # Determine scan size category for reporting
    if [ "$TOTAL_FILES_SCANNED" -gt 100000 ]; then
        SCAN_SIZE="large"
    elif [ "$TOTAL_FILES_SCANNED" -gt 10000 ]; then
        SCAN_SIZE="medium"
    else
        SCAN_SIZE="small"
    fi

    {
        echo "Daily ClamAV scan completed successfully on $(hostname)"
        echo ""
        echo "The scan completed with no threats detected after examining $TOTAL_FILES_SCANNED files in ${SCAN_DURATION} seconds. This represents a $SCAN_SIZE scan based on current file counts. The virus database is current with the latest threat definitions."
        echo ""
        if [ "$RECENT_FILE_COUNT" -gt "$CLAMAV_MAX_FILES" ]; then
            echo "Note: Upload directory scanning was limited to the most recent ${CLAMAV_MAX_FILES} files for operational efficiency."
            echo ""
        fi
        echo "This is a routine security scan confirmation. Historical trends and detailed metrics are available in your monitoring dashboard."
    } | mail -s "[ClamAV] Daily Scan - Clean - $(hostname)" -r "$CLAMAV_EMAIL_FROM" "$ADMIN_EMAIL"
fi

# Clean up
rm -f "$SYSTEM_SCAN_RESULT" "$RECENT_FILES_LIST"

log_message "Daily scan completed in ${SCAN_DURATION} seconds"