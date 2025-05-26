#!/bin/bash
set -euo pipefail
umask 077

# Configuration
DATE_STAMP=$(date +"%Y%m%d")
REPORT_FILE="/var/log/lynis/reports/report-${DATE_STAMP}.log"
LOG_FILE="/var/log/lynis/history/scan-${DATE_STAMP}.log"
ADMIN_EMAIL="sysadmin@example.com"

# Start scan
echo "Starting Lynis scan $(date)" > "$REPORT_FILE"
echo "=====================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# Run Lynis with our custom profile
/usr/sbin/lynis audit system --profile /etc/lynis/custom.prf --auditor 'SOC2 Compliance' --cronjob >> "$REPORT_FILE" 2>> "$LOG_FILE"

# Copy the files to our dated versions
mv /var/log/lynis-report.dat "$REPORT_FILE"
mv /var/log/lynis.log "$LOG_FILE"

# Analyze report for warnings and suggestions
WARNINGS=$(grep -c "Warning:" "$REPORT_FILE")
SUGGESTIONS=$(grep -c "Suggestion:" "$REPORT_FILE")
TOTAL_ISSUES=$((WARNINGS + SUGGESTIONS))

# Create summary section
{
  echo ""
  echo "======================================"
  echo "LYNIS SCAN SUMMARY ($(date))"
  echo "======================================"
  echo "Total warnings: $WARNINGS"
  echo "Total suggestions: $SUGGESTIONS"
  echo "Total issues to address: $TOTAL_ISSUES"
  echo ""

  # Extract hardening index
  HARDENING_INDEX=$(grep "Hardening index" "$REPORT_FILE" | awk -F: '{print $2}' | tr -d ' ')
  echo "Hardening index: $HARDENING_INDEX"

  # Add critical warnings for easier review
  echo ""
  echo "CRITICAL WARNINGS (requiring attention):"
  echo "======================================"
  grep "Warning:" "$REPORT_FILE" | sort | uniq

  echo ""
  echo "REPORT LOCATION: $REPORT_FILE"
  echo "LOG LOCATION: $LOG_FILE"
} >> "$REPORT_FILE"

# Send email notification with scan report
if [ $TOTAL_ISSUES -gt 0 ]; then
  mail -s "[SECURITY] Lynis scan completed - $TOTAL_ISSUES issues found (${DATE_STAMP})" "$ADMIN_EMAIL" < "$REPORT_FILE"
else
  mail -s "[SECURITY] Lynis scan completed - No issues found (${DATE_STAMP})" "$ADMIN_EMAIL" < "$REPORT_FILE"
fi

exit 0