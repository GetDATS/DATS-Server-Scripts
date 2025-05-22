#!/bin/bash
set -euo pipefail
umask 077

# Load configuration
if [ ! -f "/etc/soc2-scripts/config/clamav-scan.conf" ]; then
    echo "ERROR: Configuration file not found at /etc/soc2-scripts/config/clamav-scan.conf"
    echo "Please create it based on the documentation"
    exit 1
fi

source /etc/soc2-scripts/config/common.conf
source /etc/soc2-scripts/config/clamav-scan.conf

# Configuration variables
LOG_FILE="${LOG_DIR}/dailyscan-$(date +%Y%m%d).log"

# Start log entry
echo "ClamAV targeted scan started: $(date)" >> "$LOG_FILE"

# Ensure the ClamAV service is running
if ! systemctl is-active --quiet clamav-daemon; then
   echo "ClamAV daemon not running. Attempting to start..." >> "$LOG_FILE"
   systemctl start clamav-daemon
   sleep 5
fi

# Scan each directory
echo "SCANNING DIRECTORIES:" >> "$LOG_FILE"
for DIR in "${SCAN_DIRS[@]}"; do
   echo "Scanning $DIR..." >> "$LOG_FILE"
   clamdscan --multiscan --fdpass --infected --move="$QUARANTINE_DIR" "$DIR" >> "$LOG_FILE" 2>&1
   echo "" >> "$LOG_FILE"
done

# Record scan results
SCAN_RESULT=$?
case $SCAN_RESULT in
   0)  echo "No virus found." >> "$LOG_FILE" ;;
   1)  echo "Virus(es) found and moved to quarantine." >> "$LOG_FILE"
       echo "Alerting administrators..." >> "$LOG_FILE"
       mail -s "[SECURITY ALERT] Virus detected on $(hostname)" "$ADMIN_EMAIL" < "$LOG_FILE"
       ;;
   2)  echo "Scan error occurred." >> "$LOG_FILE" ;;
esac

echo "ClamAV scan completed: $(date)" >> "$LOG_FILE"

# Create a symbolic link to the latest scan for convenience
ln -sf "$LOG_FILE" "/var/log/clamav/latest_scan.log"

exit 0