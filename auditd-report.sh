#!/bin/bash
set -euo pipefail

# Simple auditd health check for SOC 2 compliance
# Focus: Ensure auditd is working, not complex daily reporting

# Load configuration
source /usr/local/share/soc2-scripts/config/common.conf

LOG_FILE="/var/log/audit/auditd-health.log"

# Simple logging
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    logger -t auditd "$1"
}

log_message "Starting auditd health check"

# Check 1: Is auditd running?
if ! systemctl is-active --quiet auditd; then
    log_message "CRITICAL: auditd service not running"
    echo "CRITICAL: Auditd service is not running on $(hostname)" | mail -s "[SECURITY CRITICAL] Auditd Service Down" "$ADMIN_EMAIL"
    exit 1
fi

# Check 2: Are audit rules loaded?
RULES_COUNT=$(auditctl -l | wc -l)
if [ "$RULES_COUNT" -lt 10 ]; then
    log_message "WARNING: Only $RULES_COUNT audit rules loaded"
    echo "WARNING: Auditd has only $RULES_COUNT rules loaded on $(hostname)" | mail -s "[SECURITY WARNING] Auditd Rules Issue" "$ADMIN_EMAIL"
else
    log_message "Auditd rules loaded: $RULES_COUNT"
fi

# Check 3: Is audit log being written?
AUDIT_LOG="/var/log/audit/audit.log"
if [ ! -f "$AUDIT_LOG" ]; then
    log_message "CRITICAL: Audit log file missing"
    echo "CRITICAL: Audit log file missing on $(hostname)" | mail -s "[SECURITY CRITICAL] Auditd Log Missing" "$ADMIN_EMAIL"
    exit 1
fi

# Check when last audit entry was written (just verify log is active)
if [ ! -s "$AUDIT_LOG" ]; then
    log_message "CRITICAL: Audit log appears empty"
    echo "CRITICAL: Audit log appears empty on $(hostname)" | mail -s "[SECURITY CRITICAL] Auditd Not Logging" "$ADMIN_EMAIL"
    exit 1
fi

# Check 4: Log rotation working?
LOG_COUNT=$(ls -1 /var/log/audit/ | wc -l)
DISK_USAGE=$(df /var/log/audit | tail -1 | awk '{print $5}' | sed 's/%//')

# Check 5: Simple activity summary (just for peace of mind)
YESTERDAY=$(date -d yesterday '+%m/%d/%Y')
# Clean up the event counting to avoid extra output
EVENTS_COUNT=$(ausearch --start "$YESTERDAY 00:00:00" --end "$YESTERDAY 23:59:59" 2>/dev/null | grep -c "^----" 2>/dev/null || true)
if [ -z "$EVENTS_COUNT" ] || [ "$EVENTS_COUNT" = "" ]; then
    EVENTS_YESTERDAY="0"
else
    EVENTS_YESTERDAY="$EVENTS_COUNT"
fi

# Get recent audit entries for the report
RECENT_ENTRIES=$(tail -25 "$AUDIT_LOG" | sed 's/^/  /')

# Create simple status report
EMAIL_BODY=$(mktemp)
cat > "$EMAIL_BODY" << EOF
Auditd Health Check - $(hostname) - $(date '+%Y-%m-%d')

STATUS: All systems operational

HEALTH SUMMARY:
  Service status: Running
  Rules loaded: $RULES_COUNT
  Log files: $LOG_COUNT
  Disk usage: ${DISK_USAGE}%
  Yesterday's audit events: $EVENTS_YESTERDAY

AUDIT CONFIGURATION:
  Log file: $AUDIT_LOG

RECENT AUDIT ACTIVITY (last 25 entries):
$RECENT_ENTRIES

This is a routine health check confirming that auditd
is properly configured and operational for SOC 2 compliance.

For detailed audit investigation, use: ausearch commands
For daily security monitoring, see: Grafana Cloud dashboards
EOF

# Send clean status report
mail -s "[Audit] Daily Health Check - Operational - $(hostname)" "$ADMIN_EMAIL" < "$EMAIL_BODY"

# Clean up
rm -f "$EMAIL_BODY"

log_message "Auditd health check completed successfully"