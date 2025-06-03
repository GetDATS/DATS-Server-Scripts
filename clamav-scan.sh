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

# Count files scanned and infected
FILES_SCANNED=$(grep -c "OK$\|FOUND$" "$SCAN_RESULT" 2>/dev/null || echo "0")
INFECTED_COUNT=$(grep -c "FOUND" "$SCAN_RESULT" 2>/dev/null || echo "0")

# Log structured metrics for Grafana
log_metrics "$FILES_SCANNED" "$INFECTED_COUNT" "$SCAN_STATUS"

# Handle results
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
    } | mail -s "SECURITY ALERT: Malware Found" "$ADMIN_EMAIL"
else
    log_message "Scan completed - $FILES_SCANNED files scanned, no threats found"
fi

# Clean up
rm -f "$SCAN_RESULT"

log_message "Daily scan completed"