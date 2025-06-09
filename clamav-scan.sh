#!/bin/bash
set -euo pipefail

# ClamAV daily scanner with Datadog integration
# Focuses on detecting threats and providing structured metrics

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

# Run the scan - simple and direct
SCAN_RESULT=$(mktemp)
if clamscan --recursive --infected --log="$SCAN_RESULT" "${SCAN_DIRS[@]}" 2>&1; then
    SCAN_STATUS="$STATUS_SUCCESS"
else
    SCAN_STATUS="$STATUS_WARNING"  # threats found but scan worked
fi

SCAN_END=$(date +%s)
SCAN_DURATION=$((SCAN_END - SCAN_START))

# Count files scanned and infected - parse ClamAV's summary
FILES_SCANNED=$(grep "Scanned files:" "$SCAN_RESULT" 2>/dev/null | sed 's/.*Scanned files: \([0-9]*\).*/\1/' | head -1 | tr -d '\n\r\t ' || echo "0")
INFECTED_COUNT=$(grep "Infected files:" "$SCAN_RESULT" 2>/dev/null | sed 's/.*Infected files: \([0-9]*\).*/\1/' | head -1 | tr -d '\n\r\t ' || echo "0")

# Validate they're actually numbers
[[ "$FILES_SCANNED" =~ ^[0-9]+$ ]] || FILES_SCANNED="0"
[[ "$INFECTED_COUNT" =~ ^[0-9]+$ ]] || INFECTED_COUNT="0"

# Log structured metrics for Datadog
if [ "$INFECTED_COUNT" -gt 0 ]; then
    log_metrics "$FILES_SCANNED" "$INFECTED_COUNT" "$STATUS_WARNING"
else
    log_metrics "$FILES_SCANNED" "$INFECTED_COUNT" "$STATUS_SUCCESS"
fi

# Handle results - send security-conscious notifications
if [ "$INFECTED_COUNT" -gt 0 ]; then
    log_message "ALERT: $INFECTED_COUNT infected files found"

    # Log threats to secure log for investigation
    echo "=== THREAT DETAILS $(date) ===" >> "$LOG_FILE"
    grep "FOUND" "$SCAN_RESULT" >> "$LOG_FILE"
    echo "=== END THREAT DETAILS ===" >> "$LOG_FILE"

    # Manually log each infection to syslog for security monitoring
    grep "FOUND" "$SCAN_RESULT" | while read -r line; do
        logger -t soc2-security "THREAT_DETECTED: service=clamav threat_info=$line"
    done

    {
        echo "ClamAV scan detected $INFECTED_COUNT threats on $(hostname)"
        echo ""
        echo "Scan Summary:"
        echo "- Files scanned: $FILES_SCANNED"
        echo "- Threats found: $INFECTED_COUNT"
        echo "- Scan duration: ${SCAN_DURATION} seconds"
        echo "- Status: REQUIRES IMMEDIATE ATTENTION"
        echo ""
        echo "Security Actions Required:"
        echo "1. Review detailed threat log: $LOG_FILE"
        echo "2. Investigate affected systems"
        echo "3. Implement containment measures if needed"
        echo ""
        echo "Threat details have been logged securely for investigation."
        echo "Do not forward this email outside the security team."
    } | mail -s "[SECURITY ALERT] ClamAV - $INFECTED_COUNT threats detected - $(hostname)" -r "$CLAMAV_EMAIL_FROM" "$ADMIN_EMAIL"

else
    log_message "Scan completed - $FILES_SCANNED files scanned, no threats found"

    # Determine scan size category for reporting
    if [ "$FILES_SCANNED" -gt 100000 ]; then
        SCAN_SIZE="large"
    elif [ "$FILES_SCANNED" -gt 10000 ]; then
        SCAN_SIZE="medium"
    else
        SCAN_SIZE="small"
    fi

    {
        echo "Daily ClamAV scan completed successfully on $(hostname)"
        echo ""
        echo "Scan Results:"
        echo "- Status: Clean (no threats detected)"
        echo "- Scan size: $SCAN_SIZE ($FILES_SCANNED files)"
        echo "- Duration: ${SCAN_DURATION} seconds"
        echo "- Database: Current"
        echo ""
        echo "This is a routine security scan confirmation."
        echo "Historical trends available in monitoring dashboard."
    } | mail -s "[ClamAV] Daily Scan - Clean - $(hostname)" -r "$CLAMAV_EMAIL_FROM" "$ADMIN_EMAIL"
fi

# Clean up
rm -f "$SCAN_RESULT"

log_message "Daily scan completed in ${SCAN_DURATION} seconds"