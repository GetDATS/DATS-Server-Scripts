#!/bin/bash
set -euo pipefail
umask 077

source /etc/soc2-scripts/config/common.conf
source /etc/soc2-scripts/config/auditd-report.conf

DATE_STAMP=$(date +%Y%m%d)
REPORT_FILE="${LOG_DIR}/daily-report-${DATE_STAMP}.txt"
TEMP_FILE="/tmp/auditd-${DATE_STAMP}.tmp"

ausearch --start yesterday --format raw > "$TEMP_FILE"

{
  echo "AUDITD REPORT FOR $(date)"
  echo "Host: $(hostname)"
  echo "=============================="
  echo ""
} > "$REPORT_FILE"

TOTAL_EVENTS=$(wc -l < "$TEMP_FILE" || echo 0)
FAILED_LOGIN_COUNT=$(grep -Ei 'res=failed|FAILED|failed' "$TEMP_FILE" | grep -E 'USER_LOGIN|USER_AUTH' | wc -l || echo 0)

echo "Total audit events: $TOTAL_EVENTS" >> "$REPORT_FILE"
echo "Failed login attempts: $FAILED_LOGIN_COUNT" >> "$REPORT_FILE"

mail -s "[AUDIT] Daily Audit Report - $(hostname) - $(date +%F)" "$ADMIN_EMAIL" < "$REPORT_FILE"

[ -f "$REPORT_FILE" ] && gzip -9 "$REPORT_FILE"