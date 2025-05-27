#!/bin/bash
set -euo pipefail
umask 077

# Load configuration files following established pattern
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/lynis-scan.conf

# Generate timestamped filenames for audit trail
DATE_STAMP=$(date +%Y%m%d)
REPORT_FILE="${LOG_DIR}/report-${DATE_STAMP}.txt"
LOG_FILE="${LOG_DIR}/scan-${DATE_STAMP}.log"

# Log scan initiation to syslog for Grafana Cloud integration
logger -p daemon.notice "LYNIS SECURITY SCAN: Starting comprehensive security assessment"

# Ensure log directory exists with proper permissions
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    chmod 750 "$LOG_DIR"
fi

# Execute comprehensive Lynis scan (removed --quick for thorough SOC 2 compliance assessment)
# The scan examines system configuration, security settings, and compliance posture
if ! /usr/bin/lynis audit system --logfile "$LOG_FILE" --report-file "$REPORT_FILE" --profile /etc/lynis/custom.prf; then
    # Log failure to syslog for monitoring integration
    logger -p daemon.error "LYNIS SECURITY SCAN: Scan execution failed - check system status"
    echo "Lynis scan execution failed on $(date)" | mail -s "[SECURITY ERROR] Lynis scan failed - $(hostname) - ${DATE_STAMP}" "$ADMIN_EMAIL"
    exit 1
fi

# Count security findings using comprehensive pattern matching
# Lynis uses varied terminology for different finding types and severities
WARNINGS=$(grep -c "Warning:" "$REPORT_FILE" 2>/dev/null || echo 0)
SUGGESTIONS=$(grep -c "Suggestion:" "$REPORT_FILE" 2>/dev/null || echo 0)
MANUAL_ITEMS=$(grep -c "Manual:" "$REPORT_FILE" 2>/dev/null || echo 0)
TOTAL_ISSUES=$((WARNINGS + SUGGESTIONS + MANUAL_ITEMS))

# Extract hardening index for trend monitoring
HARDENING_INDEX=$(grep "Hardening index" "$REPORT_FILE" | awk '{print $4}' | tr -d '[]' || echo "Unknown")

# Append scan summary with context for administrator review
{
    echo ""
    echo "=================================="
    echo "SCAN SUMMARY"
    echo "=================================="
    echo "Scan completed: $(date)"
    echo "Host: $(hostname)"
    echo "Warnings found: $WARNINGS"
    echo "Suggestions found: $SUGGESTIONS"
    echo "Manual review items: $MANUAL_ITEMS"
    echo "Total findings: $TOTAL_ISSUES"
    echo "Hardening index: $HARDENING_INDEX"
    echo ""
    echo "Log file: $LOG_FILE"
    echo "Full report: $REPORT_FILE"
} >> "$REPORT_FILE"

# Send appropriate notification based on findings
if [ "$TOTAL_ISSUES" -gt 0 ]; then
    # Log significant findings to syslog for security monitoring
    logger -p daemon.warning "LYNIS SECURITY SCAN: Found $TOTAL_ISSUES security findings requiring review"

    # Email detailed results to administrators
    mail -s "[SECURITY] Lynis scan - $TOTAL_ISSUES findings on $(hostname) - ${DATE_STAMP}" "$ADMIN_EMAIL" < "$REPORT_FILE"
else
    # Log clean scan result for compliance tracking
    logger -p daemon.notice "LYNIS SECURITY SCAN: No security issues found - system hardening verified"

    # Send confirmation of clean scan
    mail -s "[SECURITY] Lynis scan - No issues found on $(hostname) - ${DATE_STAMP}" "$ADMIN_EMAIL" < "$REPORT_FILE"
fi

# Create convenience symlinks for quick access to latest results
# These help administrators quickly access current scan status
ln -sf "$LOG_FILE" "${LOG_DIR}/latest_scan.log" 2>/dev/null || true
ln -sf "$REPORT_FILE" "${LOG_DIR}/latest_report.txt" 2>/dev/null || true

# Log successful completion for audit trail
logger -p daemon.notice "LYNIS SECURITY SCAN: Completed successfully with $TOTAL_ISSUES findings"

exit 0