#!/bin/bash
# OpenSCAP compliance scan with week-over-week regression detection.
# oscap exits 2 whenever any rule fails, so this script does not use set -e.
set -uo pipefail

# Load configuration
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/openscap-scan.conf

# Variables
DATE_STAMP=$(date +%Y%m%d)
RESULTS="$LOG_DIR/openscap-results-$DATE_STAMP.xml"
REPORT="$LOG_DIR/openscap-report-$DATE_STAMP.html"
FAILS="$LOG_DIR/openscap-fails-$DATE_STAMP.txt"
SUMMARY_LOG="$LOG_DIR/openscap-scan.log"
EMAIL_CONTENT=$(mktemp)
PARSED=$(mktemp)
trap 'rm -f "$EMAIL_CONTENT" "$PARSED"' EXIT

mkdir -p "$LOG_DIR"

# The summary log is shipped to Datadog, which reads it through the adm group
[ -f "$SUMMARY_LOG" ] || install -m 0640 -g adm /dev/null "$SUMMARY_LOG"

log_summary() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$SUMMARY_LOG"
    logger -t soc2-openscap "$1"
}

fail_and_exit() {
    log_summary "SCAN_FAILED: service=openscap status=$STATUS_ERROR error=$1"
    echo "OpenSCAP scan could not complete on $SERVER_NAME: $1" | \
        mail -s "[OpenSCAP ERROR] Scan failed - $SERVER_NAME" -r "$OPENSCAP_EMAIL_FROM" "$ADMIN_EMAIL"
    exit 1
}

# Pre-flight: scan content must be in place
[ -r "$OPENSCAP_DATASTREAM" ] || fail_and_exit "datastream_missing path=$OPENSCAP_DATASTREAM"
[ -r "$OPENSCAP_TAILORING" ] || fail_and_exit "tailoring_missing path=$OPENSCAP_TAILORING"

# The most recent earlier fail list is the baseline for regression detection
PREVIOUS=$(ls -1 "$LOG_DIR"/openscap-fails-*.txt 2>/dev/null | grep -v -- "-$DATE_STAMP.txt" | sort | tail -1 || true)

# Run scan
SCAN_START=$(date +%s)
oscap xccdf eval \
    --profile "$OPENSCAP_PROFILE" \
    --tailoring-file "$OPENSCAP_TAILORING" \
    --results "$RESULTS" \
    --report "$REPORT" \
    "$OPENSCAP_DATASTREAM" > /dev/null 2>&1
OSCAP_EXIT=$?
SCAN_DURATION=$(( $(date +%s) - SCAN_START ))

# 0 = every rule passed, 2 = at least one rule failed; anything else is a scanner error
if [ "$OSCAP_EXIT" -ne 0 ] && [ "$OSCAP_EXIT" -ne 2 ]; then
    fail_and_exit "oscap_exit_$OSCAP_EXIT"
fi
[ -s "$RESULTS" ] || fail_and_exit "no_results_file"

# Extract failing rule ids. In XCCDF the outcome is a child <result> element
# of each <rule-result>, not an attribute.
python3 - "$RESULTS" > "$PARSED" << 'EOF'
import sys
import xml.etree.ElementTree as ET

ln = lambda e: e.tag.split("}")[-1]
tr = [e for e in ET.parse(sys.argv[1]).getroot().iter() if ln(e) == "TestResult"][-1]
for rr in tr.iter():
    if ln(rr) == "rule-result":
        res = next((c.text.strip() for c in rr if ln(c) == "result" and c.text), None)
        if res == "fail":
            print(rr.get("idref", "").replace("xccdf_org.ssgproject.content_rule_", ""))
EOF
PARSE_EXIT=$?
[ "$PARSE_EXIT" -eq 0 ] || fail_and_exit "results_parse_failed"
sort "$PARSED" > "$FAILS"

# Keep the full results compact; the fail list and HTML report cover day-to-day use
gzip -9f "$RESULTS"

# Compare with the previous scan
TOTAL_FAILS=$(wc -l < "$FAILS" | tr -d ' ')
if [ -n "$PREVIOUS" ]; then
    NEW_FAILS=$(comm -13 "$PREVIOUS" "$FAILS")
    RESOLVED=$(comm -23 "$PREVIOUS" "$FAILS")
    BASELINE=$(basename "$PREVIOUS")
else
    NEW_FAILS=""
    RESOLVED=""
    BASELINE="none - first scan"
fi
NEW_COUNT=$(printf '%s' "$NEW_FAILS" | grep -c . || true)
RESOLVED_COUNT=$(printf '%s' "$RESOLVED" | grep -c . || true)

# Create email
{
    echo "OpenSCAP Compliance Scan - $SERVER_NAME"
    echo "================================================================================"
    echo ""
    echo "Profile:          $OPENSCAP_PROFILE"
    echo "Content version:  SSG $OPENSCAP_CONTENT_VERSION"
    echo "Failing rules:    $TOTAL_FAILS"
    echo "New failures:     $NEW_COUNT (compared with $BASELINE)"
    echo "No longer failing: $RESOLVED_COUNT"
    echo "Duration:         ${SCAN_DURATION} seconds"
    echo "Report:           $REPORT"
    echo ""
    if [ "$NEW_COUNT" -gt 0 ]; then
        echo "ACTION REQUIRED - rules failing now that were not failing in the previous scan:"
        echo "$NEW_FAILS" | sed 's/^/  /'
        echo ""
        echo "A rule that passed and now fails usually means a package upgrade or a"
        echo "configuration change has reverted a control. Investigate before accepting it."
        echo ""
    fi
    if [ "$RESOLVED_COUNT" -gt 0 ]; then
        echo "No longer failing:"
        echo "$RESOLVED" | sed 's/^/  /'
        echo ""
    fi
    echo "All failing rules (each should be a documented exception):"
    sed 's/^/  /' "$FAILS"
} > "$EMAIL_CONTENT"

# Determine subject and status
if [ "$NEW_COUNT" -gt 0 ]; then
    SUBJECT="[OpenSCAP REGRESSION] $NEW_COUNT new failing rule(s) - $SERVER_NAME"
    STATUS="$STATUS_WARNING"
else
    SUBJECT="[OpenSCAP] $TOTAL_FAILS failing, no new failures - $SERVER_NAME"
    STATUS="$STATUS_SUCCESS"
fi

# Send email
mail -s "$SUBJECT" -r "$OPENSCAP_EMAIL_FROM" "$ADMIN_EMAIL" < "$EMAIL_CONTENT"

# Log metrics
log_summary "OPERATION_COMPLETE: service=openscap operation=compliance_scan failed_rules=$TOTAL_FAILS new_failures=$NEW_COUNT resolved=$RESOLVED_COUNT content_version=$OPENSCAP_CONTENT_VERSION status=$STATUS duration_seconds=$SCAN_DURATION"

if [ "$NEW_COUNT" -gt 0 ]; then
    log_summary "REGRESSION: service=openscap new_failures=$NEW_COUNT rules=$(echo "$NEW_FAILS" | paste -sd, -)"
    logger -t soc2-security "SECURITY_FINDINGS: service=openscap new_failures=$NEW_COUNT severity=high"
fi

# Cleanup old files - the S3 log archive keeps the long-term copies
find "$LOG_DIR" -name "openscap-results-*.xml.gz" -mtime +90 -delete 2>/dev/null || true
find "$LOG_DIR" -name "openscap-report-*.html" -mtime +90 -delete 2>/dev/null || true
find "$LOG_DIR" -name "openscap-fails-*.txt" -mtime +400 -delete 2>/dev/null || true

exit 0
