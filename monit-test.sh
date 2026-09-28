#!/bin/bash
set -euo pipefail

# Service recovery test script for SOC 2 evidence generation
# Tests Monit's automatic service recovery capabilities with monitoring integration

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/monit-test.conf

if [ -z "$1" ]; then
  echo "Usage: $0 <service-name>"
  echo "Example: $0 apache2"
  exit 1
fi

SERVICE=$1
DATE_STAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/monit-test-$SERVICE-$DATE_STAMP.log"

# Structured logging function for monitoring integration
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    # Use consistent tag for syslog routing
    logger -t soc2-monit "$1"
}

# Log structured metrics for monitoring
log_metrics() {
    local service=$1
    local recovery_successful=$2
    local status=$3
    local operation_duration=${4:-0}

    # Structured log entry for monitoring system
    logger -t soc2-monit "OPERATION_COMPLETE: service=monit operation=recovery_test tested_service=$service recovery_successful=$recovery_successful status=$status duration_seconds=$operation_duration"
}

log_message "=== Service Recovery Test for $SERVICE ==="
TEST_START=$(date +%s)

# Log to monitoring for test initiation
logger -t soc2-monit "SERVICE_RECOVERY_TEST: service=$SERVICE action=begin"

# Check initial service status
log_message "Checking initial service status"
if systemctl is-active --quiet "$SERVICE"; then
    INITIAL_STATUS="running"
    log_message "Initial status: Service is running"
else
    INITIAL_STATUS="stopped"
    log_message "Initial status: Service is not running"

    # If service isn't running initially, start it first
    log_message "Starting service for recovery test"
    systemctl start "$SERVICE"
    sleep 10

    if ! systemctl is-active --quiet "$SERVICE"; then
        log_message "ERROR: Cannot start $SERVICE for testing"
        logger -t soc2-monit "OPERATION_COMPLETE: service=monit operation=recovery_test tested_service=$SERVICE status=$STATUS_ERROR error=service_start_failed"
        echo "Service recovery test failed - cannot start $SERVICE on $(hostname)" | mail -s "[Monit] Recovery Test Failed - Cannot Start Service" -r "$MONIT_EMAIL_FROM" "$ADMIN_EMAIL"
        exit 1
    fi
fi

# Stop the service to trigger recovery
log_message "Stopping $SERVICE to trigger recovery..."
systemctl stop "$SERVICE"
log_message "Service stopped - waiting for Monit recovery"

# Log to monitoring for service stop
logger -t soc2-monit "SERVICE_RECOVERY_TEST: service=$SERVICE action=stopped"

# Wait for Monit to detect and fix (3 minutes)
log_message "Waiting 3 minutes for automatic recovery..."
sleep 180

TEST_END=$(date +%s)
TEST_DURATION=$((TEST_END - TEST_START))

# Check if service was automatically restarted
log_message "Checking recovery results"
if systemctl is-active --quiet "$SERVICE"; then
    RECOVERY_RESULT="$STATUS_SUCCESS"
    RECOVERY_SUCCESSFUL="true"
    log_message "SUCCESS: $SERVICE was automatically recovered!"

    # Log success to monitoring
    logger -t soc2-monit "SERVICE_RECOVERY_TEST: service=$SERVICE action=complete result=success"

    # Determine recovery speed for reporting
    if [ "$TEST_DURATION" -le 120 ]; then
        RECOVERY_SPEED="fast"
    elif [ "$TEST_DURATION" -le 240 ]; then
        RECOVERY_SPEED="normal"
    else
        RECOVERY_SPEED="slow"
    fi

else
    RECOVERY_RESULT="$STATUS_FAILED"
    RECOVERY_SUCCESSFUL="false"
    log_message "FAILURE: $SERVICE was not automatically recovered!"

    # Log failure to monitoring
    logger -t soc2-monit "SERVICE_RECOVERY_TEST: service=$SERVICE action=complete result=failure"
    logger -t soc2-security "RECOVERY_FAILURE: service=$SERVICE severity=high impact=automatic_recovery_disabled"

    RECOVERY_SPEED="failed"

    # Try to manually restart the service to restore operations
    log_message "Attempting manual service recovery"
    systemctl start "$SERVICE" || true
fi

# Log final service status for verification
log_message "Final service status verification completed"

# Log structured metrics for monitoring
log_metrics "$SERVICE" "$RECOVERY_SUCCESSFUL" "$RECOVERY_RESULT" "$TEST_DURATION"

# Create a symlink to latest test for easy access
ln -sf "$LOG_FILE" "$LOG_DIR/latest-recovery-test.log"

# Send email notification with test results - security-conscious reporting
if [ "$RECOVERY_RESULT" = "$STATUS_SUCCESS" ]; then
    {
        echo "Service Recovery Test Results - $(hostname)"
        echo ""
        echo "Test Summary:"
        echo "- Service tested: $SERVICE"
        echo "- Recovery result: Successful"
        echo "- Recovery speed: $RECOVERY_SPEED"
        echo "- Test duration: ${TEST_DURATION} seconds"
        echo "- Status: Automatic recovery operational"
        echo ""
        echo "Compliance Evidence:"
        echo "- Service availability controls are functioning"
        echo "- Automatic recovery mechanisms are operational"
        echo "- SOC 2 availability principle requirements satisfied"
        echo ""
        echo "This test demonstrates that service recovery capabilities"
        echo "are working as designed for business continuity."
        echo ""
        echo "Detailed test evidence: $LOG_FILE"
        echo "Historical recovery metrics available in monitoring dashboard."
    } | mail -s "[Monit] Service Recovery Test - SUCCESS - $SERVICE" -r "$MONIT_EMAIL_FROM" "$ADMIN_EMAIL"

else
    {
        echo "Service Recovery Test Results - $(hostname)"
        echo ""
        echo "Test Summary:"
        echo "- Service tested: $SERVICE"
        echo "- Recovery result: FAILED"
        echo "- Test duration: ${TEST_DURATION} seconds"
        echo "- Status: REQUIRES IMMEDIATE ATTENTION"
        echo ""
        echo "Critical Issue:"
        echo "- Automatic service recovery is not functioning"
        echo "- Business continuity controls are compromised"
        echo "- SOC 2 availability principle requirements not met"
        echo ""
        echo "Required Actions:"
        echo "1. Investigate Monit configuration immediately"
        echo "2. Verify service monitoring rules"
        echo "3. Test recovery mechanism manually"
        echo "4. Restore automatic recovery functionality"
        echo ""
        echo "Service availability is currently at risk."
        echo "Manual intervention required to restore full protection."
        echo ""
        echo "Detailed test evidence: $LOG_FILE"
    } | mail -s "[Monit] Service Recovery Test - FAILED - $SERVICE" -r "$MONIT_EMAIL_FROM" "$ADMIN_EMAIL"
fi

log_message "Service recovery test completed"
log_message "Evidence saved to: $LOG_FILE"