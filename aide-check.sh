#!/bin/bash
set -euo pipefail
umask 077

DATE_STAMP=$(date +%F.%H%M)
REPORT_DIR=/var/log/aide/reports
DB_ARCHIVE=/var/lib/aide/archive
mkdir -p "$REPORT_DIR" "$DB_ARCHIVE"
LOG_FILE="$REPORT_DIR/aide_report_$DATE_STAMP.log"
ADMIN_EMAIL="sysadmin@example.com"

# run the check
/usr/bin/aide --check --config=/etc/aide/aide.conf > "$LOG_FILE"

# alert if critical paths changed
if grep -qE '[a-z]\+.*(/etc/|/boot/|/usr/local/bin/|/var/log/archives/)' "$LOG_FILE"; then
    logger -p auth.notice "AIDE critical change – see $LOG_FILE"
    mail -s "[SECURITY ALERT] AIDE Critical File Changes Detected" "$ADMIN_EMAIL" < "$LOG_FILE"
fi

# every Sunday copy the current db, then update it
if [ "$(date +%u)" -eq 7 ]; then
    cp /var/lib/aide/aide.db "$DB_ARCHIVE/aide.db_$DATE_STAMP"
    /usr/bin/aide --update --config=/etc/aide/aide.conf
    cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
fi

# trim old evidence (≥ 365 days)
find "$REPORT_DIR" -type f -mtime +365 -delete
find "$DB_ARCHIVE" -type f -mtime +365 -delete