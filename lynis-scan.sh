#!/bin/bash
set -euo pipefail
umask 077

source /etc/soc2-scripts/config/common.conf
source /etc/soc2-scripts/config/lynis-scan.conf

DATE_STAMP=$(date +%Y%m%d)
REPORT_FILE="${LOG_DIR}/report-${DATE_STAMP}.txt"
LOG_FILE="${LOG_DIR}/scan-${DATE_STAMP}.log"

if ! /usr/bin/lynis audit system --quick --logfile "$LOG_FILE" --report-file "$REPORT_FILE"; then
  echo "Lynis scan failed." | mail -s "[SECURITY] Lynis scan failed (${DATE_STAMP})" "$ADMIN_EMAIL"
  exit 1
fi

TOTAL_ISSUES=$(grep -c "Warning:" "$REPORT_FILE")

{
  echo ""
  echo "Scan completed on: $(date)"
  echo "Host: $(hostname)"
} >> "$REPORT_FILE"

if [ "$TOTAL_ISSUES" -gt 0 ]; then
  mail -s "[SECURITY] Lynis scan completed - $TOTAL_ISSUES issues found (${DATE_STAMP})" "$ADMIN_EMAIL" < "$REPORT_FILE"
else
  mail -s "[SECURITY] Lynis scan completed - No issues found (${DATE_STAMP})" "$ADMIN_EMAIL" < "$REPORT_FILE"
fi

ln -sf "$LOG_FILE" "${LOG_DIR}/latest_scan.log" 2_
