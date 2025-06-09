#!/bin/bash
set -euo pipefail

# Lynis security scanner with monitoring integration
# Focuses on security assessment without unnecessary complexity

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/lynis-scan.conf

# Generate timestamped filenames
DATE_STAMP=$(date +%Y%m%d)
REPORT_FILE="$LOG_DIR/lynis-report-$DATE_STAMP.txt"
LOG_FILE="$LOG_DIR/lynis-scan-$DATE_STAMP.log"

# Structured logging function for monitoring integration
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    # Use consistent tag for syslog routing
    logger -t soc2-lynis "$1"
}

# Log structured metrics for monitoring
log_metrics() {
    local warnings=$1
    local suggestions=$2
    local manual_items=$3
    local hardening_index=$4
    local status=$5
    local operation_duration=${6:-0}

    # Structured log entry for monitoring system
    logger -t soc2-lynis "OPERATION_COMPLETE: service=lynis operation=security_scan warnings=$warnings suggestions=$suggestions manual_items=$manual_items hardening_index=$hardening_index status=$status duration_seconds=$operation_duration"
}

# Ensure log directory exists
mkdir -p "$LOG_DIR"

log_message "Starting Lynis security assessment"
SCAN_START=$(date +%s)

# Run Lynis scan
if lynis audit system --logfile "$LOG_FILE" --report-file "$REPORT_FILE" --profile /etc/lynis/custom.prf 2>/dev/null; then
    SCAN_STATUS="$STATUS_SUCCESS"
else
    SCAN_STATUS="$STATUS_ERROR"
    log_message "ERROR: Lynis scan execution failed"
    logger -t soc2-lynis "OPERATION_COMPLETE: service=lynis operation=security_scan status=$STATUS_ERROR error=scan_execution_failed"
    echo "Lynis scan failed on $(hostname) at $(date)" | mail -s "[SECURITY ERROR] Lynis Scan Failed" -r "$LYNIS_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1
fi

SCAN_END=$(date +%s)
SCAN_DURATION=$((SCAN_END - SCAN_START))

# Count findings with bulletproof number extraction
WARNINGS=$(grep -c "warning\[\]" "$REPORT_FILE" 2>/dev/null | head -1 | tr -d '\n\r\t ' || echo "0")
SUGGESTIONS=$(grep -c "suggestion\[\]" "$REPORT_FILE" 2>/dev/null | head -1 | tr -d '\n\r\t ' || echo "0")
MANUAL_ITEMS=$(grep -c "manual\[\]" "$REPORT_FILE" 2>/dev/null | head -1 | tr -d '\n\r\t ' || echo "0")

# Validate they're actually numbers
[[ "$WARNINGS" =~ ^[0-9]+$ ]] || WARNINGS="0"
[[ "$SUGGESTIONS" =~ ^[0-9]+$ ]] || SUGGESTIONS="0"
[[ "$MANUAL_ITEMS" =~ ^[0-9]+$ ]] || MANUAL_ITEMS="0"

TOTAL_ISSUES=$((WARNINGS + SUGGESTIONS + MANUAL_ITEMS))

# Extract hardening index
HARDENING_INDEX=$(grep "^hardening_index=" "$REPORT_FILE" 2>/dev/null | cut -d'=' -f2 || echo "0")
[[ "$HARDENING_INDEX" =~ ^[0-9]+$ ]] || HARDENING_INDEX="0"

# Determine overall status based on findings
if [ "$WARNINGS" -gt 0 ]; then
    FINAL_STATUS="$STATUS_WARNING"
else
    FINAL_STATUS="$STATUS_SUCCESS"
fi

# Log structured metrics for monitoring
log_metrics "$WARNINGS" "$SUGGESTIONS" "$MANUAL_ITEMS" "$HARDENING_INDEX" "$FINAL_STATUS" "$SCAN_DURATION"

# Handle results - send security-conscious notifications
if [ "$WARNINGS" -gt 0 ]; then
    log_message "Security scan completed - $WARNINGS warnings requiring attention"

    # Log detailed findings to secure log for investigation
    echo "=== SECURITY WARNINGS $(date) ===" >> "$LOG_FILE"
    grep "warning\[\]" "$REPORT_FILE" >> "$LOG_FILE"
    echo "=== END SECURITY WARNINGS ===" >> "$LOG_FILE"

    # Log security events for monitoring
    logger -t soc2-security "SECURITY_FINDINGS: service=lynis warnings=$WARNINGS suggestions=$SUGGESTIONS severity=medium"

    # Determine warning severity for reporting
    if [ "$WARNINGS" -gt 10 ]; then
        WARNING_SCALE="high"
    elif [ "$WARNINGS" -gt 5 ]; then
        WARNING_SCALE="medium"
    else
        WARNING_SCALE="low"
    fi

    {
        echo "Lynis security scan found $WARNINGS warnings on $(hostname)"
        echo ""
        echo "Scan Results:"
        echo "- Warnings: $WARNING_SCALE severity ($WARNINGS items requiring attention)"
        echo "- Suggestions: $SUGGESTIONS (recommendations for improvement)"
        echo "- Manual items: $MANUAL_ITEMS (items requiring review)"
        echo "- Total findings: $TOTAL_ISSUES"
        echo "- Hardening index: $HARDENING_INDEX"
        echo "- Scan duration: ${SCAN_DURATION} seconds"
        echo ""
        echo "Security Actions Required:"
        echo "1. Review detailed findings: $REPORT_FILE"
        echo "2. Address critical warnings first"
        echo "3. Plan remediation for remaining items"
        echo ""
        echo "Detailed security findings have been logged securely for review."
        echo "Focus on addressing warnings to improve security posture."
    } | mail -s "[SECURITY WARNING] Lynis Scan - $WARNINGS warnings - $(hostname)" -r "$LYNIS_EMAIL_FROM" "$ADMIN_EMAIL"

elif [ "$TOTAL_ISSUES" -gt 0 ]; then
    log_message "Security scan completed - $TOTAL_ISSUES findings (suggestions/manual only)"

    # Determine finding scale for reporting
    if [ "$TOTAL_ISSUES" -gt 20 ]; then
        FINDING_SCALE="large"
    elif [ "$TOTAL_ISSUES" -gt 10 ]; then
        FINDING_SCALE="medium"
    else
        FINDING_SCALE="small"
    fi

    {
        echo "Lynis security scan completed on $(hostname)"
        echo ""
        echo "Scan Results:"
        echo "- Warnings: 0 (no critical issues found)"
        echo "- Suggestions: $FINDING_SCALE scale ($SUGGESTIONS recommendations)"
        echo "- Manual items: $MANUAL_ITEMS (items for review)"
        echo "- Total findings: $TOTAL_ISSUES"
        echo "- Hardening index: $HARDENING_INDEX"
        echo "- Scan duration: ${SCAN_DURATION} seconds"
        echo ""
        echo "No critical warnings found - system security posture is good."
        echo "Consider reviewing suggestions for further security improvements."
        echo ""
        echo "Historical security trends available in monitoring dashboard."
    } | mail -s "[Lynis] Security Scan - $TOTAL_ISSUES suggestions - $(hostname)" -r "$LYNIS_EMAIL_FROM" "$ADMIN_EMAIL"

else
    log_message "Security scan completed - no issues found"
    {
        echo "Lynis security scan completed successfully on $(hostname)"
        echo ""
        echo "Scan Results:"
        echo "- Warnings: 0"
        echo "- Suggestions: 0"
        echo "- Manual items: 0"
        echo "- Total findings: 0"
        echo "- Hardening index: $HARDENING_INDEX"
        echo "- Scan duration: ${SCAN_DURATION} seconds"
        echo ""
        echo "Excellent! No security issues found."
        echo "This indicates a well-hardened system configuration."
        echo ""
        echo "Continue regular security assessments to maintain this status."
        echo "Historical security posture trends available in monitoring dashboard."
    } | mail -s "[Lynis] Security Scan - Clean - $(hostname)" -r "$LYNIS_EMAIL_FROM" "$ADMIN_EMAIL"
fi

log_message "Security assessment completed"