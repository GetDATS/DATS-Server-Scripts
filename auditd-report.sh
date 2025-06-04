#!/bin/bash
set -euo pipefail

# Simple auditd report with Grafana Cloud integration
# Focuses on security events without insane complexity

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/auditd-report.conf

LOG_FILE="$LOG_DIR/auditd-report.log"

# Grafana-friendly logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    # Use 'auditd' tag so rsyslog routes to Grafana Cloud logs
    logger -t auditd "$1"
}

# Check if auditd is running and has data
if ! systemctl is-active --quiet auditd; then
    log_message "ERROR: auditd service not running"
    echo "Auditd service is not running on $(hostname)" | mail -s "[SECURITY ERROR] Auditd Not Running" "$ADMIN_EMAIL"
    exit 1
fi

log_message "Starting daily audit report"

# Get yesterday's audit events
AUDIT_RESULT=$(mktemp)
if ! ausearch --start yesterday --end today --format text > "$AUDIT_RESULT" 2>/dev/null; then
    log_message "WARNING: No audit events found for yesterday"
    echo "No audit events found for $(date -d yesterday +%F)" > "$AUDIT_RESULT"
fi

# Count security events with bulletproof parsing
FAILED_LOGINS=$(grep -c "authentication failure\|failed login\|FAILED_LOGIN" "$AUDIT_RESULT" 2>/dev/null | head -1 | tr -d '\n\r\t ' || echo "0")
SUDO_COMMANDS=$(grep -c "sudo:" "$AUDIT_RESULT" 2>/dev/null | head -1 | tr -d '\n\r\t ' || echo "0")
CRITICAL_FILE_CHANGES=$(grep -cE "/etc/passwd|/etc/shadow|/etc/sudoers|/etc/ssh/" "$AUDIT_RESULT" 2>/dev/null | head -1 | tr -d '\n\r\t ' || echo "0")
TOTAL_EVENTS=$(wc -l < "$AUDIT_RESULT" 2>/dev/null | tr -d '\n\r\t ' || echo "0")

# Validate numbers
[[ "$FAILED_LOGINS" =~ ^[0-9]+$ ]] || FAILED_LOGINS="0"
[[ "$SUDO_COMMANDS" =~ ^[0-9]+$ ]] || SUDO_COMMANDS="0"
[[ "$CRITICAL_FILE_CHANGES" =~ ^[0-9]+$ ]] || CRITICAL_FILE_CHANGES="0"
[[ "$TOTAL_EVENTS" =~ ^[0-9]+$ ]] || TOTAL_EVENTS="0"

# Calculate concern level
SECURITY_CONCERNS=$((FAILED_LOGINS + CRITICAL_FILE_CHANGES))

# Log structured metrics for Grafana
logger -t auditd "AUDIT_REPORT: failed_logins=$FAILED_LOGINS sudo_commands=$SUDO_COMMANDS critical_changes=$CRITICAL_FILE_CHANGES total_events=$TOTAL_EVENTS"

# Handle results based on what we found
if [ "$SECURITY_CONCERNS" -gt 5 ]; then
    log_message "CRITICAL: $SECURITY_CONCERNS security events requiring immediate attention"
    {
        echo "🚨 CRITICAL SECURITY EVENTS DETECTED 🚨"
        echo "======================================="
        echo ""
        echo "HOST: $(hostname)"
        echo "PERIOD: $(date -d yesterday +%F)"
        echo ""
        echo "⚠️  SECURITY EVENTS:"
        echo "   • Failed logins: $FAILED_LOGINS"
        echo "   • Critical file changes: $CRITICAL_FILE_CHANGES"
        echo "   • Sudo commands: $SUDO_COMMANDS"
        echo "   • Total audit events: $TOTAL_EVENTS"
        echo ""
        if [ "$FAILED_LOGINS" -gt 0 ]; then
            echo "🔍 FAILED LOGIN ATTEMPTS:"
            grep -i "authentication failure\|failed login" "$AUDIT_RESULT" | head -10
            echo ""
        fi
        if [ "$CRITICAL_FILE_CHANGES" -gt 0 ]; then
            echo "🔍 CRITICAL FILE CHANGES:"
            grep -E "/etc/passwd|/etc/shadow|/etc/sudoers|/etc/ssh/" "$AUDIT_RESULT" | head -10
            echo ""
        fi
        echo "📋 FULL AUDIT OUTPUT:"
        echo "===================="
        cat "$AUDIT_RESULT"
    } | mail -s "[SECURITY CRITICAL] Audit Report - $SECURITY_CONCERNS security events - $(hostname)" "$ADMIN_EMAIL"

elif [ "$SECURITY_CONCERNS" -gt 0 ]; then
    log_message "WARNING: $SECURITY_CONCERNS security events detected"
    {
        echo "Audit report for $(hostname) - $(date -d yesterday +%F)"
        echo ""
        echo "Security Events Summary:"
        echo "• Failed logins: $FAILED_LOGINS"
        echo "• Critical file changes: $CRITICAL_FILE_CHANGES"
        echo "• Sudo commands: $SUDO_COMMANDS"
        echo "• Total audit events: $TOTAL_EVENTS"
        echo ""
        if [ "$FAILED_LOGINS" -gt 0 ]; then
            echo "Failed login details:"
            grep -i "authentication failure\|failed login" "$AUDIT_RESULT" | head -5
            echo ""
        fi
        if [ "$CRITICAL_FILE_CHANGES" -gt 0 ]; then
            echo "Critical file changes:"
            grep -E "/etc/passwd|/etc/shadow|/etc/sudoers|/etc/ssh/" "$AUDIT_RESULT" | head -5
            echo ""
        fi
    } | mail -s "[SECURITY WARNING] Audit Report - $SECURITY_CONCERNS events - $(hostname)" "$ADMIN_EMAIL"

else
    log_message "Daily audit report completed - no security concerns"
    {
        echo "Daily audit report for $(hostname) - $(date -d yesterday +%F)"
        echo ""
        echo "Security Status: ✅ Clean"
        echo ""
        echo "Activity Summary:"
        echo "• Failed logins: $FAILED_LOGINS"
        echo "• Critical file changes: $CRITICAL_FILE_CHANGES"
        echo "• Sudo commands: $SUDO_COMMANDS"
        echo "• Total audit events: $TOTAL_EVENTS"
        echo ""
        echo "No security concerns detected."
        echo "This is a routine audit report confirmation."
    } | mail -s "[Audit] Daily Report - Clean - $(hostname)" "$ADMIN_EMAIL"
fi

# Clean up
rm -f "$AUDIT_RESULT"

log_message "Daily audit report completed"