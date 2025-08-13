#!/bin/bash
# AIDE file integrity checker with automatic baseline refresh

set -u
set -o pipefail

# AIDE exit codes: 0=clean, 1-7=changes detected, 8+=errors

# Load configuration
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/aide-check.conf

# Set up variables
LOG_DIR="/var/log/aide"
LOG_FILE="$LOG_DIR/aide-$(date +%Y%m%d-%H%M%S).log"
ADMIN_EMAIL="${ADMIN_EMAIL:-sysadmin@getdats.com}"

mkdir -p "$LOG_DIR"

# Check if AIDE is properly set up
if [ ! -f "/var/lib/aide/aide.db" ]; then
    echo "ERROR: AIDE database missing - run 'aide --init' first" | \
        mail -s "[AIDE ERROR] Database missing - $(hostname)" -r "$AIDE_EMAIL_FROM" "$ADMIN_EMAIL"
    logger -t soc2-aide "CHECK_FAILED: error=database_missing status=$STATUS_ERROR"
    exit 1
fi

# Run AIDE check
echo "Starting AIDE check at $(date)" > "$LOG_FILE"
echo "----------------------------------------" >> "$LOG_FILE"
aide --check --config=/etc/aide/aide.conf >> "$LOG_FILE" 2>&1
CHANGES=$?

echo "AIDE exit code: $CHANGES" >> "$LOG_FILE"

# Initialize counters
CHANGED=0
ADDED=0
REMOVED=0
TOTAL=0

# Determine status and subject line
if [ $CHANGES -eq 0 ]; then
    SUBJECT="[AIDE] Clean - $(hostname)"
    STATUS="$STATUS_SUCCESS"
elif [ $CHANGES -ge 1 ] && [ $CHANGES -le 7 ]; then
    # Count changes for subject line
    CHANGED=$(grep -c "^changed:" "$LOG_FILE" 2>/dev/null) || CHANGED=0
    ADDED=$(grep -c "^added:" "$LOG_FILE" 2>/dev/null) || ADDED=0
    REMOVED=$(grep -c "^removed:" "$LOG_FILE" 2>/dev/null) || REMOVED=0

    TOTAL=$((CHANGED + ADDED + REMOVED))

    if [ $TOTAL -gt 0 ]; then
        SUBJECT="[AIDE] $TOTAL changes - $(hostname)"
    else
        SUBJECT="[AIDE] Changes detected - $(hostname)"
    fi
    STATUS="$STATUS_WARNING"
else
    SUBJECT="[AIDE ERROR] Check failed - $(hostname)"
    STATUS="$STATUS_ERROR"
fi

# Log metrics for Datadog
logger -t soc2-aide "CHECK_COMPLETE: service=aide operation=integrity_check status=$STATUS exit_code=$CHANGES total_changes=$TOTAL"

# Refresh database after changes detected
if [ $CHANGES -ge 1 ] && [ $CHANGES -le 7 ]; then
    echo "" >> "$LOG_FILE"
    echo "----------------------------------------" >> "$LOG_FILE"
    echo "Database refresh triggered (exit code $CHANGES indicates changes)" >> "$LOG_FILE"
    echo "Refreshing database at $(date)" >> "$LOG_FILE"

    # Archive on Sundays for SOC 2
    if [ $(date +%u) -eq 7 ]; then
        mkdir -p "$DB_ARCHIVE"
        if cp /var/lib/aide/aide.db "$DB_ARCHIVE/aide.db_$(date +%Y%m%d)" 2>/dev/null; then
            echo "Database archived to $DB_ARCHIVE/aide.db_$(date +%Y%m%d)" >> "$LOG_FILE"
        fi
        find "$DB_ARCHIVE" -name "aide.db_*" -mtime +84 -delete 2>/dev/null || true
    fi

    # Update database
    echo "Running: aide --update --config=/etc/aide/aide.conf" >> "$LOG_FILE"
    aide --update --config=/etc/aide/aide.conf >> "$LOG_FILE" 2>&1
    UPDATE_EXIT=$?

    if [ $UPDATE_EXIT -ge 0 ] && [ $UPDATE_EXIT -le 7 ]; then
        echo "aide --update completed (exit code $UPDATE_EXIT)" >> "$LOG_FILE"
        if [ -f /var/lib/aide/aide.db.new ]; then
            echo "New database exists, moving into place" >> "$LOG_FILE"
            if mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db 2>/dev/null; then
                echo "Database successfully refreshed" >> "$LOG_FILE"
                logger -t soc2-aide "DATABASE_REFRESHED: status=$STATUS_SUCCESS"
            else
                echo "ERROR: Failed to move new database into place" >> "$LOG_FILE"
                logger -t soc2-aide "DATABASE_REFRESH_FAILED: status=$STATUS_ERROR error=mv_failed"
            fi
        else
            echo "ERROR: aide --update didn't create aide.db.new" >> "$LOG_FILE"
            logger -t soc2-aide "DATABASE_REFRESH_FAILED: status=$STATUS_ERROR error=no_new_db"
        fi
    else
        echo "ERROR: aide --update command failed with exit code $UPDATE_EXIT" >> "$LOG_FILE"
        logger -t soc2-aide "DATABASE_REFRESH_FAILED: status=$STATUS_ERROR error=update_failed exit_code=$UPDATE_EXIT"
    fi
else
    echo "No database refresh needed (exit code $CHANGES)" >> "$LOG_FILE"
fi

# Email the results
if ! mail -s "$SUBJECT" -r "$AIDE_EMAIL_FROM" "$ADMIN_EMAIL" < "$LOG_FILE"; then
    logger -t soc2-aide "EMAIL_FAILED: subject=\"$SUBJECT\" status=$STATUS_ERROR"
    echo "ERROR: Failed to send email notification" >&2
fi

exit 0