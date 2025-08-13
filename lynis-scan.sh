#!/bin/bash
set -euo pipefail

# Load configuration
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/lynis-scan.conf

# Variables
DATE_STAMP=$(date +%Y%m%d)
TIME_STAMP=$(date +%Y%m%d-%H%M%S)
SCAN_OUTPUT="$LOG_DIR/lynis-output-$TIME_STAMP.txt"
REPORT_DATA="$LOG_DIR/lynis-report-$TIME_STAMP.dat"
EMAIL_CONTENT="$LOG_DIR/lynis-email-$TIME_STAMP.txt"

mkdir -p "$LOG_DIR"

# Initialize scan log
cat > "$SCAN_OUTPUT" << EOF
================================================================================
LYNIS SECURITY SCAN - $SERVER_NAME
$(date '+%Y-%m-%d %H:%M:%S')
================================================================================

EOF

SCAN_START=$(date +%s)

# Run scan
echo "Running security audit..." >> "$SCAN_OUTPUT"

TEMP_OUTPUT=$(mktemp)
if lynis audit system \
    --no-colors \
    --quick \
    --report-file "$REPORT_DATA" \
    --profile /etc/lynis/custom.prf 2>&1 | tee "$TEMP_OUTPUT"; then
    SCAN_STATUS="success"
else
    SCAN_STATUS="error"
    SCAN_EXIT=$?
fi

# Strip terminal control codes
cat "$TEMP_OUTPUT" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' | \
    sed 's/\[[0-9]*[CK]//g' | \
    tr -d '\000-\010\013-\037' >> "$SCAN_OUTPUT"
rm -f "$TEMP_OUTPUT"

SCAN_END=$(date +%s)
SCAN_DURATION=$((SCAN_END - SCAN_START))

# Extract metrics from report
WARNINGS="0"
SUGGESTIONS="0"
HARDENING_INDEX="0"

if [ -f "$REPORT_DATA" ]; then
    WARNINGS=$(grep -E "^warning\[\]" "$REPORT_DATA" 2>/dev/null | wc -l | tr -d ' ')
    SUGGESTIONS=$(grep -E "^suggestion\[\]" "$REPORT_DATA" 2>/dev/null | wc -l | tr -d ' ')
    HARDENING_LINE=$(grep -E "^hardening_index=" "$REPORT_DATA" 2>/dev/null || true)
    if [ -n "$HARDENING_LINE" ]; then
        HARDENING_INDEX=$(echo "$HARDENING_LINE" | cut -d'=' -f2 | tr -d ' ')
    fi
fi

# Validate numbers
[[ "$WARNINGS" =~ ^[0-9]+$ ]] || WARNINGS="0"
[[ "$SUGGESTIONS" =~ ^[0-9]+$ ]] || SUGGESTIONS="0"
[[ "$HARDENING_INDEX" =~ ^[0-9]+$ ]] || HARDENING_INDEX="0"

# Add completion info
cat >> "$SCAN_OUTPUT" << EOF

================================================================================
SCAN COMPLETED
================================================================================
Duration: ${SCAN_DURATION} seconds
Report: $REPORT_DATA
$(date '+%Y-%m-%d %H:%M:%S')

EOF

# Extract findings from report
echo "=================================================================================" >> "$SCAN_OUTPUT"
echo "FINDINGS" >> "$SCAN_OUTPUT"
echo "=================================================================================" >> "$SCAN_OUTPUT"
echo "" >> "$SCAN_OUTPUT"

if [ -f "$REPORT_DATA" ] && [ "$WARNINGS" -gt "0" ]; then
    echo "WARNINGS:" >> "$SCAN_OUTPUT"
    echo "---------" >> "$SCAN_OUTPUT"
    grep -E "^warning\[\]" "$REPORT_DATA" 2>/dev/null | while IFS= read -r line; do
        WARNING_INFO=$(echo "$line" | sed 's/warning\[\]=//' | sed 's/|/ - /g')
        echo "  $WARNING_INFO" >> "$SCAN_OUTPUT"
    done
    echo "" >> "$SCAN_OUTPUT"
fi

if [ -f "$REPORT_DATA" ] && [ "$SUGGESTIONS" -gt "0" ]; then
    SHOW_COUNT=30
    echo "SUGGESTIONS (showing up to $SHOW_COUNT):" >> "$SCAN_OUTPUT"
    echo "-----------------------------------" >> "$SCAN_OUTPUT"
    grep -E "^suggestion\[\]" "$REPORT_DATA" 2>/dev/null | head -$SHOW_COUNT | while IFS= read -r line; do
        SUGGESTION_INFO=$(echo "$line" | sed 's/suggestion\[\]=//' | sed 's/|/ - /g')
        echo "  $SUGGESTION_INFO" >> "$SCAN_OUTPUT"
    done
    if [ "$SUGGESTIONS" -gt "$SHOW_COUNT" ]; then
        echo "  ... plus $((SUGGESTIONS - SHOW_COUNT)) more" >> "$SCAN_OUTPUT"
    fi
    echo "" >> "$SCAN_OUTPUT"
fi

# Create email
cat > "$EMAIL_CONTENT" << EOF
Lynis Security Scan - $SERVER_NAME
================================================================================

SUMMARY
-------
Warnings:        $WARNINGS
Suggestions:     $SUGGESTIONS
Hardening Index: $HARDENING_INDEX/100
Duration:        ${SCAN_DURATION} seconds
Date:            $(date '+%Y-%m-%d %H:%M:%S')

EOF

if [ "$WARNINGS" -gt "0" ]; then
    echo "ACTION REQUIRED: $WARNINGS warning(s) found" >> "$EMAIL_CONTENT"
    echo "" >> "$EMAIL_CONTENT"
elif [ "$HARDENING_INDEX" -lt "70" ]; then
    echo "Hardening score below threshold (70)" >> "$EMAIL_CONTENT"
    echo "" >> "$EMAIL_CONTENT"
fi

# Append full output
echo "=================================================================================" >> "$EMAIL_CONTENT"
echo "FULL OUTPUT" >> "$EMAIL_CONTENT"
echo "=================================================================================" >> "$EMAIL_CONTENT"
echo "" >> "$EMAIL_CONTENT"
cat "$SCAN_OUTPUT" >> "$EMAIL_CONTENT"

# Determine subject
if [ "$WARNINGS" -gt "0" ]; then
    SUBJECT="[Lynis WARNING] $WARNINGS warnings - $SERVER_NAME"
elif [ "$HARDENING_INDEX" -lt "60" ]; then
    SUBJECT="[Lynis] Low score: $HARDENING_INDEX - $SERVER_NAME"
else
    SUBJECT="[Lynis] Score: $HARDENING_INDEX, $SUGGESTIONS suggestions - $SERVER_NAME"
fi

# Send email
mail -s "$SUBJECT" -r "$LYNIS_EMAIL_FROM" "$ADMIN_EMAIL" < "$EMAIL_CONTENT"

# Log metrics
logger -t soc2-lynis "OPERATION_COMPLETE: service=lynis operation=security_scan warnings=$WARNINGS suggestions=$SUGGESTIONS hardening_index=$HARDENING_INDEX status=$SCAN_STATUS duration_seconds=$SCAN_DURATION"

if [ "$WARNINGS" -gt "0" ]; then
    logger -t soc2-security "SECURITY_FINDINGS: service=lynis warnings=$WARNINGS severity=high"
fi

# Cleanup old files
find "$LOG_DIR" -name "lynis-output-*.txt" -mtime +30 -delete 2>/dev/null || true
find "$LOG_DIR" -name "lynis-report-*.dat" -mtime +90 -delete 2>/dev/null || true
find "$LOG_DIR" -name "lynis-email-*.txt" -mtime +7 -delete 2>/dev/null || true

exit 0