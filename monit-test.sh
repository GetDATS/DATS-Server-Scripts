#!/bin/bash
set -euo pipefail

# Service recovery test script for SOC 2 evidence generation
# Tests Monit's automatic service recovery capabilities with Datadog integration

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/monit-test.conf

DATE=$(date +%Y%m%d-%H%M%S)
mkdir -p "$LOG_DIR"

if [ -z "$1" ]; then
  echo "Usage: $0 <service-name>"
  echo "Example: $0 apache2"
  exit 1
fi

SERVICE=$1
LOG_FILE="$LOG_DIR/$DATE-$SERVICE-test.log"

# Datadog-friendly logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    # Use 'monit-test' tag for Datadog routing
    logger -t monit-test "$1"
}

log_message "=== Service Recovery Test for $SERVICE ==="

# Log to syslog for Datadog capture
logger -t monit-test "SERVICE_RECOVERY_TEST: service=$SERVICE action=begin"

# Get initial status
log_message "Initial service status:"
systemctl status "$SERVICE" 2>&1 | tee -a "$LOG_FILE"

# Stop the service
log_message "Stopping $SERVICE to trigger recovery..."
systemctl stop "$SERVICE"
log_message "Service stopped at $(date)"

# Log to syslog for Datadog capture
logger -t monit-test "SERVICE_RECOVERY_TEST: service=$SERVICE action=stopped"

# Wait for Monit to detect and fix
log_message "Waiting 3 minutes for recovery..."
sleep 180

# Check if service was restarted
log_message "Checking if $SERVICE was automatically restarted:"
if systemctl is-active --quiet "$SERVICE"; then
  log_message "SUCCESS: $SERVICE was automatically recovered!"
  RESULT="SUCCESS"
else
  log_message "FAILURE: $SERVICE was not automatically recovered!"
  RESULT="FAILURE"
fi

# Log to syslog for Datadog capture
logger -t monit-test "SERVICE_RECOVERY_TEST: service=$SERVICE action=complete result=$RESULT"

# Get final status and Monit logs
log_message "Final service status:"
systemctl status "$SERVICE" 2>&1 | tee -a "$LOG_FILE"

log_message "Relevant Monit log entries:"
grep "$SERVICE" /var/log/monit.log | tail -20 | tee -a "$LOG_FILE"

log_message "Test completed at $(date)"
log_message "Evidence saved to: $LOG_FILE"

# Create a symlink to latest test
ln -sf "$LOG_FILE" "$LOG_DIR/latest-recovery-test.log"

# Send email notification with test results
{
    echo "Service Recovery Test Results - $(hostname)"
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Service: $SERVICE"
    echo "Result: $RESULT"
    echo ""
    echo "This test demonstrates automatic service recovery capabilities"
    echo "for SOC 2 compliance and availability principle requirements."
    echo ""
    echo "Evidence file: $LOG_FILE"
    echo "View recovery metrics in your Datadog dashboard."
} | mail -s "[Monit] Service Recovery Test - $RESULT - $SERVICE" "$ADMIN_EMAIL"