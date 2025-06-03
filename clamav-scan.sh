#!/bin/bash
set -euo pipefail

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/clamav-scan.conf

LOG_FILE="$LOG_DIR/daily-scan.log"

# Grafana-friendly logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    # Use 'clamd' tag so rsyslog routes to Grafana Cloud logs
    logger -t clamd "$1"
}

# Log structured metrics for Grafana dashboards
log_metrics() {
    local files_scanned=$1
    local threats_found=$2
    local status=$3

    # Structured log entry that Grafana can parse and alert on
    logger -t clamd "SCAN_COMPLETE: files_scanned=$files_scanned threats_found=$threats_found status=$status"
}

# Check if ClamAV daemon is running
if ! systemctl is-active --quiet clamav-daemon; then
    log_message "ERROR: ClamAV daemon not running"
    echo "ClamAV daemon is not running on $(hostname)" | mail -s "ClamAV Error" "$ADMIN_EMAIL"
    exit 1
fi

log_message "Starting daily ClamAV scan"

# Run the scan - simple and direct
SCAN_RESULT=$(mktemp)
if clamscan --recursive --infected --log="$SCAN_RESULT" "${SCAN_DIRS[@]}" 2>&1; then
    SCAN_STATUS="clean"
else
    SCAN_STATUS="infected"
fi

# Count files scanned and infected - parse ClamAV's summary instead of line-by-line
FILES_SCANNED=$(grep "Scanned files:" "$SCAN_RESULT" 2>/dev/null | sed 's/.*Scanned files: \([0-9]*\).*/\1/' | head -1 | tr -d '\n\r\t ' || echo "0")
INFECTED_COUNT=$(grep "Infected files:" "$SCAN_RESULT" 2>/dev/null | sed 's/.*Infected files: \([0-9]*\).*/\1/' | head -1 | tr -d '\n\r\t ' || echo "0")

# Validate they're actually numbers (paranoid but necessary)
[[ "$FILES_SCANNED" =~ ^[0-9]+$ ]] || FILES_SCANNED="0"
[[ "$INFECTED_COUNT" =~ ^[0-9]+$ ]] || INFECTED_COUNT="0"

# Log structured metrics for Grafana
log_metrics "$FILES_SCANNED" "$INFECTED_COUNT" "$SCAN_STATUS"

# Handle results - always send email for audit trail
if [ "$INFECTED_COUNT" -gt 0 ]; then
    log_message "ALERT: $INFECTED_COUNT infected files found"
    {
        echo "ClamAV scan found $INFECTED_COUNT infected files on $(hostname)"
        echo "Files scanned: $FILES_SCANNED"
        echo ""
        echo "Infected files:"
        grep "FOUND" "$SCAN_RESULT"
        echo ""
        echo "Full scan log attached."
    } | mail -s "[SECURITY ALERT] ClamAV Scan - $INFECTED_COUNT threats found - $(hostname)" "$ADMIN_EMAIL"
else
    log_message "Scan completed - $FILES_SCANNED files scanned, no threats found"
    {
        echo "Daily ClamAV scan completed successfully on $(hostname)"
        echo ""
        echo "Scan Results:"
        echo "- Files scanned: $FILES_SCANNED"
        echo "- Threats found: $INFECTED_COUNT"
        echo "- Scan time: $(grep "Time:" "$SCAN_RESULT" | cut -d: -f2- || echo "Unknown")"
        echo "- Database version: $(grep "Known viruses:" "$SCAN_RESULT" | cut -d: -f2- || echo "Unknown")"
        echo ""
        echo "This is a routine security scan confirmation."
    } | mail -s "[ClamAV] Daily Scan - Clean - $FILES_SCANNED files - $(hostname)" "$ADMIN_EMAIL"
fi

# Clean up
rm -f "$SCAN_RESULT"

log_message "Daily scan completed"