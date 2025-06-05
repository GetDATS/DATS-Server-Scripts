#!/bin/bash
set -euo pipefail

# Lynis security scanner with Datadog integration
# Focuses on security assessment without unnecessary complexity

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/lynis-scan.conf

# Generate timestamped filenames
DATE_STAMP=$(date +%Y%m%d)
REPORT_FILE="$LOG_DIR/report-$DATE_STAMP.txt"
LOG_FILE="$LOG_DIR/scan-$DATE_STAMP.log"

# Datadog-friendly logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    # Use 'lynis' tag for consistent syslog routing to Datadog
    logger -t lynis "$1"
}

# Ensure log directory exists
mkdir -p "$LOG_DIR"

log_message "Starting Lynis security assessment"

# Run Lynis scan
if lynis audit system --logfile "$LOG_FILE" --report-file "$REPORT_FILE" --profile /etc/lynis/custom.prf 2>/dev/null; then
    SCAN_STATUS="success"
else
    SCAN_STATUS="failed"
    log_message "ERROR: Lynis scan execution failed"
    echo "Lynis scan failed on $(hostname) at $(date)" | mail -s "[SECURITY ERROR] Lynis Scan Failed" "$ADMIN_EMAIL"
    exit 1
fi

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
HARDENING_INDEX=$(grep "^hardening_index=" "$REPORT_FILE" 2>/dev/null | cut -d'=' -f2 || echo "Unknown")

# Log structured metrics for Datadog
logger -t lynis "SECURITY_SCAN: warnings=$WARNINGS suggestions=$SUGGESTIONS manual=$MANUAL_ITEMS total=$TOTAL_ISSUES hardening_index=$HARDENING_INDEX"

# Handle results - always email for audit trail
if [ "$WARNINGS" -gt 0 ]; then
    log_message "Security scan completed - $WARNINGS warnings requiring attention"
    {
        echo "Lynis security scan found $WARNINGS warnings on $(hostname)"
        echo ""
        echo "Scan Results:"
        echo "- Warnings: $WARNINGS (require attention)"
        echo "- Suggestions: $SUGGESTIONS (recommendations)"
        echo "- Manual items: $MANUAL_ITEMS (review needed)"
        echo "- Total findings: $TOTAL_ISSUES"
        echo "- Hardening index: $HARDENING_INDEX"
        echo ""
        echo "Key warnings found:"
        grep "warning\[\]" "$REPORT_FILE" | head -10
        if [ "$WARNINGS" -gt 10 ]; then
            echo ""
            echo "(Showing first 10 of $WARNINGS warnings)"
        fi
        echo ""
        echo "View detailed security trends and analysis in your Datadog dashboard."
        echo ""
        echo "Full report:"
        echo "============"
        cat "$REPORT_FILE"
    } | mail -s "[SECURITY WARNING] Lynis Scan - $WARNINGS warnings - $(hostname)" "$ADMIN_EMAIL"

elif [ "$TOTAL_ISSUES" -gt 0 ]; then
    log_message "Security scan completed - $TOTAL_ISSUES findings (suggestions/manual only)"
    {
        echo "Lynis security scan completed on $(hostname)"
        echo ""
        echo "Scan Results:"
        echo "- Warnings: $WARNINGS"
        echo "- Suggestions: $SUGGESTIONS (recommendations)"
        echo "- Manual items: $MANUAL_ITEMS (review needed)"
        echo "- Total findings: $TOTAL_ISSUES"
        echo "- Hardening index: $HARDENING_INDEX"
        echo ""
        echo "No critical warnings found - system security posture is good."
        echo ""
        echo "View historical security trends in your Datadog dashboard."
        echo ""
        echo "Full report:"
        echo "============"
        cat "$REPORT_FILE"
    } | mail -s "[Lynis] Security Scan - $TOTAL_ISSUES suggestions - $(hostname)" "$ADMIN_EMAIL"

else
    log_message "Security scan completed - no issues found"
    {
        echo "Lynis security scan completed successfully on $(hostname)"
        echo ""
        echo "Scan Results:"
        echo "- Warnings: $WARNINGS"
        echo "- Suggestions: $SUGGESTIONS"
        echo "- Manual items: $MANUAL_ITEMS"
        echo "- Total findings: $TOTAL_ISSUES"
        echo "- Hardening index: $HARDENING_INDEX"
        echo ""
        echo "Excellent! No security issues found."
        echo "This is a routine security assessment confirmation."
        echo ""
        echo "View security posture trends in your Datadog dashboard."
        echo ""
        echo "Full report:"
        echo "============"
        cat "$REPORT_FILE"
    } | mail -s "[Lynis] Security Scan - Clean - $(hostname)" "$ADMIN_EMAIL"
fi

log_message "Security assessment completed"