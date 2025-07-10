#!/bin/bash
set -euo pipefail

# Daily backup summary report - consolidates all backup activity into one email
# Reduces notification overload while maintaining visibility

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/backup.conf

LOG_DIR="/var/log/backups"
YESTERDAY=$(date -d yesterday +%Y-%m-%d)
TODAY=$(date +%Y-%m-%d)

# Structured logging function
log_message() {
    logger -t soc2-backup "$1"
}

log_message "Generating daily backup summary"

# Function to analyze log files for a specific backup type
analyze_backup_log() {
    local log_file=$1
    local backup_type=$2
    local expected_count=$3

    if [ ! -f "$log_file" ]; then
        echo "  ⚠️  $backup_type: NO LOG FILE FOUND"
        return
    fi

    # Count successful operations from yesterday
    local success_count=$(grep -c "$YESTERDAY.*status=$STATUS_SUCCESS" "$log_file" 2>/dev/null || echo "0")
    local error_count=$(grep -c "$YESTERDAY.*ERROR" "$log_file" 2>/dev/null || echo "0")
    local warning_count=$(grep -c "$YESTERDAY.*WARNING" "$log_file" 2>/dev/null || echo "0")

    # Determine status
    local status_icon="✓"
    local status_text="Healthy"

    if [ "$error_count" -gt 0 ]; then
        status_icon="✗"
        status_text="ERRORS DETECTED"
    elif [ "$warning_count" -gt 0 ]; then
        status_icon="⚠️"
        status_text="Warnings"
    elif [ "$success_count" -lt "$expected_count" ]; then
        status_icon="⚠️"
        status_text="Incomplete"
    fi

    echo "  $status_icon $backup_type: $status_text"
    echo "     Runs: $success_count/$expected_count | Errors: $error_count | Warnings: $warning_count"

    # Get size information if available
    local total_size=$(grep "$YESTERDAY.*size_bytes=" "$log_file" 2>/dev/null | \
        awk -F'size_bytes=' '{sum+=$2} END {print sum}' | \
        awk '{print $1}' || echo "0")

    if [ "$total_size" -gt 0 ]; then
        echo "     Total size: $(numfmt --to=iec-i --suffix=B $total_size 2>/dev/null || echo "$total_size bytes")"
    fi

    # Show last error if any
    if [ "$error_count" -gt 0 ]; then
        local last_error=$(grep "$YESTERDAY.*ERROR" "$log_file" | tail -1 | cut -d' ' -f4-)
        echo "     Last error: $last_error"
    fi

    echo ""
}

# Check S3 connectivity
s3_status="Connected"
s3_object_count=0
s3_total_size=0

if aws s3 ls "s3://$AWS_BACKUP_BUCKET" >/dev/null 2>&1; then
    # Get bucket statistics for this host
    s3_stats=$(aws s3 ls "s3://$AWS_BACKUP_BUCKET" --recursive --summarize 2>/dev/null | grep "$(hostname)" | wc -l || echo "0")
    s3_object_count="$s3_stats"
else
    s3_status="DISCONNECTED"
fi

# Calculate uptime percentage (successful runs / expected runs)
total_expected=99  # 96 binlogs + 3 daily backups
total_success=$(grep -c "$YESTERDAY.*OPERATION_COMPLETE.*status=$STATUS_SUCCESS" $LOG_DIR/*.log 2>/dev/null || echo "0")
uptime_pct=$((total_success * 100 / total_expected))

# Count recent errors
recent_errors=$(grep "$YESTERDAY.*ERROR\|$TODAY.*ERROR" $LOG_DIR/*.log 2>/dev/null | wc -l || echo "0")

# Determine overall status for subject line
if [ "$recent_errors" -gt 0 ]; then
    STATUS_INDICATOR="❌ ERRORS"
elif [ "$uptime_pct" -lt 95 ]; then
    STATUS_INDICATOR="⚠️ WARNING"
else
    STATUS_INDICATOR="✅ OK"
fi

# Generate summary report
{
    echo "Daily Backup Summary Report - $(hostname)"
    echo "Report Date: $TODAY (covering $YESTERDAY)"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "BACKUP STATUS BY TYPE:"
    echo ""

    # Analyze each backup type
    analyze_backup_log "$LOG_DIR/mariadb-binlog.log" "MariaDB Binary Logs" 96
    analyze_backup_log "$LOG_DIR/mariadb-full.log" "MariaDB Full Backup" 1
    analyze_backup_log "$LOG_DIR/home-backup.log" "Home Directory" 1
    analyze_backup_log "$LOG_DIR/log-archive.log" "Log Archives" 1

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "S3 STORAGE STATUS:"
    echo "  Bucket: $AWS_BACKUP_BUCKET"
    echo "  Status: $s3_status"
    echo "  Objects for $(hostname): ~$s3_object_count"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "KEY METRICS:"
    echo "  Backup Success Rate: ${uptime_pct}%"
    echo "  Recovery Point Objective: 15 minutes (binary logs)"
    echo "  Recovery Time Objective: <1 hour (automated)"
    echo ""

    # Recent alerts section
    echo "RECENT ALERTS (last 24 hours):"
    if [ "$recent_errors" -eq 0 ]; then
        echo "  ✓ No alerts - all systems operational"
    else
        echo "  ✗ $recent_errors errors detected - review logs"
        grep "$YESTERDAY.*ERROR\|$TODAY.*ERROR" $LOG_DIR/*.log 2>/dev/null | tail -5 | while read -r line; do
            echo "    - $(echo "$line" | cut -d' ' -f4-)"
        done
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "ACTION ITEMS:"

    if [ "$recent_errors" -gt 0 ]; then
        echo "  1. Review error logs in $LOG_DIR"
        echo "  2. Verify backup integrity"
        echo "  3. Check disk space and S3 connectivity"
    else
        echo "  ✓ No action required - backups healthy"
    fi

    echo ""
    echo "Next monthly restore test: First Monday of $(date +%B)"
    echo "View real-time metrics in your Datadog dashboard"
    echo ""
    echo "This is an automated daily summary. Critical errors"
    echo "still generate immediate notifications."

} | mail -s "[Backup] Daily Summary - $(hostname) - $STATUS_INDICATOR" -r "$BACKUP_EMAIL_FROM" "$ADMIN_EMAIL"

log_message "Daily backup summary sent"

# Log metrics for this summary
logger -t soc2-backup "OPERATION_COMPLETE: service=backup operation=daily_summary success_rate=$uptime_pct total_errors=$recent_errors status=$STATUS_SUCCESS"