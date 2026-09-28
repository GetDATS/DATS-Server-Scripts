#!/bin/bash
set -euo pipefail

# Simple auditd health check for SOC 2 compliance with monitoring integration
# Focus: Ensure auditd is working, not complex daily reporting

# Load configuration
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/auditd-report.conf

LOG_FILE="$LOG_DIR/auditd-health.log"

# Structured logging function for monitoring integration
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    # Use consistent tag for syslog routing
    logger -t soc2-auditd "$1"
}

# Log structured metrics for monitoring
log_metrics() {
    local service_running=$1
    local rules_loaded=$2
    local log_file_healthy=$3
    local log_rotation_healthy=$4
    local status=$5
    local operation_duration=${6:-0}

    # Structured log entry for monitoring system
    logger -t soc2-auditd "OPERATION_COMPLETE: service=auditd operation=health_check service_running=$service_running rules_loaded=$rules_loaded log_file_healthy=$log_file_healthy log_rotation_healthy=$log_rotation_healthy status=$status duration_seconds=$operation_duration"
}

log_message "Starting auditd health check"
CHECK_START=$(date +%s)

# Initialize health status variables
SERVICE_RUNNING="false"
RULES_LOADED="false"
LOG_FILE_HEALTHY="false"
LOG_ROTATION_HEALTHY="false"
OVERALL_STATUS="$STATUS_SUCCESS"

# Check 1: Is auditd running?
if systemctl is-active --quiet auditd; then
    SERVICE_RUNNING="true"
    log_message "Auditd service is running"
else
    SERVICE_RUNNING="false"
    OVERALL_STATUS="$STATUS_ERROR"
    log_message "CRITICAL: auditd service not running"
    logger -t soc2-security "SERVICE_DOWN: service=auditd severity=critical impact=audit_logging_disabled"
    echo "CRITICAL: Auditd service is not running on $(hostname)" | mail -s "[SECURITY CRITICAL] Auditd Service Down" -r "$AUDITD_EMAIL_FROM" "$ADMIN_EMAIL"

    CHECK_END=$(date +%s)
    CHECK_DURATION=$((CHECK_END - CHECK_START))
    log_metrics "$SERVICE_RUNNING" "$RULES_LOADED" "$LOG_FILE_HEALTHY" "$LOG_ROTATION_HEALTHY" "$OVERALL_STATUS" "$CHECK_DURATION"
    exit 1
fi

# Check 2: Are audit rules loaded?
RULES_COUNT=$(auditctl -l | wc -l)
# Clean the variable with bulletproof number extraction
RULES_COUNT=$(echo "$RULES_COUNT" | head -1 | tr -d '\n\r\t ' || echo "0")
[[ "$RULES_COUNT" =~ ^[0-9]+$ ]] || RULES_COUNT="0"

if [ "$RULES_COUNT" -ge 10 ]; then
    RULES_LOADED="true"
    log_message "Auditd rules loaded: adequate coverage"

    # Determine rule coverage category for reporting
    if [ "$RULES_COUNT" -gt 50 ]; then
        RULE_COVERAGE="comprehensive"
    elif [ "$RULES_COUNT" -gt 25 ]; then
        RULE_COVERAGE="standard"
    else
        RULE_COVERAGE="basic"
    fi
else
    RULES_LOADED="false"
    OVERALL_STATUS="$STATUS_WARNING"
    log_message "WARNING: Insufficient audit rules loaded"
    logger -t soc2-security "AUDIT_CONFIG_WARNING: service=auditd issue=insufficient_rules severity=medium"
    RULE_COVERAGE="insufficient"
fi

# Check 3: Is audit log being written?
AUDIT_LOG="/var/log/audit/audit.log"
if [ ! -f "$AUDIT_LOG" ]; then
    LOG_FILE_HEALTHY="false"
    OVERALL_STATUS="$STATUS_ERROR"
    log_message "CRITICAL: Audit log file missing"
    logger -t soc2-security "AUDIT_LOG_MISSING: service=auditd severity=critical impact=no_audit_trail"
    echo "CRITICAL: Audit log file missing on $(hostname)" | mail -s "[SECURITY CRITICAL] Auditd Log Missing" -r "$AUDITD_EMAIL_FROM" "$ADMIN_EMAIL"

    CHECK_END=$(date +%s)
    CHECK_DURATION=$((CHECK_END - CHECK_START))
    log_metrics "$SERVICE_RUNNING" "$RULES_LOADED" "$LOG_FILE_HEALTHY" "$LOG_ROTATION_HEALTHY" "$OVERALL_STATUS" "$CHECK_DURATION"
    exit 1
fi

# Check if log file has content
if [ ! -s "$AUDIT_LOG" ]; then
    LOG_FILE_HEALTHY="false"
    OVERALL_STATUS="$STATUS_ERROR"
    log_message "CRITICAL: Audit log appears empty"
    logger -t soc2-security "AUDIT_LOG_EMPTY: service=auditd severity=critical impact=no_audit_events"
    echo "CRITICAL: Audit log appears empty on $(hostname)" | mail -s "[SECURITY CRITICAL] Auditd Not Logging" -r "$AUDITD_EMAIL_FROM" "$ADMIN_EMAIL"

    CHECK_END=$(date +%s)
    CHECK_DURATION=$((CHECK_END - CHECK_START))
    log_metrics "$SERVICE_RUNNING" "$RULES_LOADED" "$LOG_FILE_HEALTHY" "$LOG_ROTATION_HEALTHY" "$OVERALL_STATUS" "$CHECK_DURATION"
    exit 1
fi

LOG_FILE_HEALTHY="true"
log_message "Audit log file is healthy"

# Check 4: Log rotation working?
LOG_COUNT=$(ls -1 /var/log/audit/ | wc -l)
# Clean the variable with bulletproof number extraction
LOG_COUNT=$(echo "$LOG_COUNT" | head -1 | tr -d '\n\r\t ' || echo "0")
[[ "$LOG_COUNT" =~ ^[0-9]+$ ]] || LOG_COUNT="0"

DISK_USAGE=$(df /var/log/audit | tail -1 | awk '{print $5}' | sed 's/%//')
# Clean the variable with bulletproof number extraction
DISK_USAGE=$(echo "$DISK_USAGE" | head -1 | tr -d '\n\r\t ' || echo "0")
[[ "$DISK_USAGE" =~ ^[0-9]+$ ]] || DISK_USAGE="0"

if [ "$LOG_COUNT" -ge 2 ] && [ "$DISK_USAGE" -lt 90 ]; then
    LOG_ROTATION_HEALTHY="true"
    log_message "Log rotation is working properly"

    # Determine disk usage category for reporting
    if [ "$DISK_USAGE" -lt 50 ]; then
        DISK_STATUS="healthy"
    elif [ "$DISK_USAGE" -lt 75 ]; then
        DISK_STATUS="moderate"
    else
        DISK_STATUS="high"
    fi
else
    LOG_ROTATION_HEALTHY="false"
    if [ "$DISK_USAGE" -ge 90 ]; then
        OVERALL_STATUS="$STATUS_WARNING"
        log_message "WARNING: High disk usage in audit directory"
        logger -t soc2-security "DISK_USAGE_HIGH: service=auditd severity=medium impact=potential_log_loss"
        DISK_STATUS="critical"
    else
        DISK_STATUS="unknown"
    fi
fi

# Check 5: Recent activity verification (just confirm audit events are being generated)
YESTERDAY=$(date -d yesterday '+%m/%d/%Y')
EVENTS_COUNT=$(ausearch --start "$YESTERDAY 00:00:00" --end "$YESTERDAY 23:59:59" 2>/dev/null | grep -c "^----" 2>/dev/null || echo "0")
# Clean the variable with bulletproof number extraction
EVENTS_COUNT=$(echo "$EVENTS_COUNT" | head -1 | tr -d '\n\r\t ' || echo "0")
[[ "$EVENTS_COUNT" =~ ^[0-9]+$ ]] || EVENTS_COUNT="0"

# Determine activity level for reporting
if [ "$EVENTS_COUNT" -gt 1000 ]; then
    ACTIVITY_LEVEL="high"
elif [ "$EVENTS_COUNT" -gt 100 ]; then
    ACTIVITY_LEVEL="normal"
elif [ "$EVENTS_COUNT" -gt 0 ]; then
    ACTIVITY_LEVEL="low"
else
    ACTIVITY_LEVEL="none"
fi

CHECK_END=$(date +%s)
CHECK_DURATION=$((CHECK_END - CHECK_START))

# Log structured health metrics for monitoring
log_metrics "$SERVICE_RUNNING" "$RULES_LOADED" "$LOG_FILE_HEALTHY" "$LOG_ROTATION_HEALTHY" "$OVERALL_STATUS" "$CHECK_DURATION"

# Create status report based on overall health
if [ "$OVERALL_STATUS" = "$STATUS_SUCCESS" ]; then
    log_message "Auditd health check completed successfully"
    {
        echo "Auditd Health Check - $(hostname) - $(date '+%Y-%m-%d')"
        echo ""
        echo "STATUS: All systems operational"
        echo ""
        echo "Health Summary:"
        echo "- Service status: Running"
        echo "- Rule coverage: $RULE_COVERAGE"
        echo "- Log file: Healthy"
        echo "- Disk usage: $DISK_STATUS"
        echo "- Activity level: $ACTIVITY_LEVEL"
        echo "- Check duration: ${CHECK_DURATION} seconds"
        echo ""
        echo "Audit logging is properly configured and operational"
        echo "for SOC 2 compliance and security monitoring."
        echo ""
        echo "Historical audit metrics available in monitoring dashboard."
    } | mail -s "[Audit] Daily Health Check - Operational - $(hostname)" -r "$AUDITD_EMAIL_FROM" "$ADMIN_EMAIL"

elif [ "$OVERALL_STATUS" = "$STATUS_WARNING" ]; then
    log_message "Auditd health check completed with warnings"
    {
        echo "Auditd Health Check - $(hostname) - $(date '+%Y-%m-%d')"
        echo ""
        echo "STATUS: Operational with warnings"
        echo ""
        echo "Health Summary:"
        echo "- Service status: Running"
        echo "- Rule coverage: $RULE_COVERAGE"
        echo "- Log file: Healthy"
        echo "- Disk usage: $DISK_STATUS"
        echo "- Activity level: $ACTIVITY_LEVEL"
        echo "- Check duration: ${CHECK_DURATION} seconds"
        echo ""
        echo "Audit logging is operational but requires attention."
        echo "Review detailed health metrics for specific issues."
        echo ""
        echo "Action may be required to maintain optimal performance."
    } | mail -s "[Audit] Daily Health Check - Warning - $(hostname)" -r "$AUDITD_EMAIL_FROM" "$ADMIN_EMAIL"
fi

log_message "Auditd health check completed"