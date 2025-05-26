#!/bin/bash
set -e
umask 077

# Configuration
DATE_STAMP=$(date +"%Y%m%d")
REPORT_FILE="/var/log/audit/daily-report-${DATE_STAMP}.txt"
ADMIN_EMAIL="sysadmin@example.com"
TEMP_FILE=$(mktemp /tmp/auditd-search.XXXXXX)

# Ensure temp file cleanup on script exit
trap 'rm -f "$TEMP_FILE"' EXIT

# Run ausearch once and store all results
echo "Gathering audit data..."
ausearch -i --start today > "$TEMP_FILE" 2>/dev/null || echo "No audit data found for today" > "$TEMP_FILE"

# Initialize report file
echo "Auditd Daily Report - $(date)" > "$REPORT_FILE"
echo "=====================================" >> "$REPORT_FILE"

# Helper function to add section headers
add_section() {
    echo -e "\n$1" >> "$REPORT_FILE"
    printf -v underline '%*s' ${#1} ''
    echo "${underline// /-}" >> "$REPORT_FILE"
}

# Helper function to handle empty results
handle_output() {
    if [ -n "$1" ]; then
        echo "$1" >> "$REPORT_FILE"
    else
        echo "$2" >> "$REPORT_FILE"
    fi
}

add_section "AUDIT EVENTS BY CATEGORY"
EVENTS=$(grep key= "$TEMP_FILE" | awk -F'key=' '{print $2}' | sort | uniq -c | sort -nr)
handle_output "$EVENTS" "No categorized events found today."

add_section "FAILED AUTHENTICATION ATTEMPTS"
FAILED_AUTH=$(grep -E "res=failed|FAILED|failed" "$TEMP_FILE" | grep -E "USER_LOGIN|USER_AUTH" |
awk '
  /acct=/ {
    match($0, /acct="?([^"[:space:])]*)("|\))?/, user)
    match($0, /addr=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/, ip)
    if (user[1] && ip[1]) {
      account = user[1]
      if (account ~ /^\(invalid/) account = "(invalid user)"
      key = account " from " ip[1]
      count[key]++
    }
  }
  END {
    if (length(count) == 0) {
      print "No failed authentication attempts found today."
    } else {
      PROCINFO["sorted_in"] = "@val_num_desc"
      for (entry in count) {
        printf("    %4d %s\n", count[entry], entry)
      }
    }
  }
')
handle_output "$FAILED_AUTH" "No failed authentication attempts found today."

add_section "FILE MODIFICATION SUMMARY"
MODS=$(grep -A 10 -B 10 "key=perm_mod" "$TEMP_FILE" | awk '
BEGIN { FS="[ =]+" }
/type=SYSCALL/ {
  match($0, /audit\(([^)]+)\)/, time_arr); timestamp = time_arr[1];
  for (i=1; i<=NF; i++) {
    if ($i == "syscall") syscall = $(i+1);
    if ($i == "exe") { exe = $(i+1); gsub(/^\/|"$/,"",exe); }
    if ($i == "auid") auid = $(i+1);
    if ($i == "uid") uid = $(i+1);
    if ($i == "comm") comm = $(i+1);
  }
  syscall_info[timestamp] = syscall " by user " auid " (real UID: " uid ") using " comm;
  exe_info[timestamp] = exe;
}
/type=PATH/ {
  match($0, /audit\(([^)]+)\)/, time_arr); timestamp = time_arr[1];
  for (i=1; i<=NF; i++) {
    if ($i == "name") { name = $(i+1); gsub(/^"|"$/,"",name); }
    if ($i == "inode") inode = $(i+1);
    if ($i == "mode") mode = $(i+1);
    if ($i == "ouid") owner = $(i+1);
    if ($i == "ogid") group = $(i+1);
  }
  if (name == "(null)" || name == "") {
    if (timestamp in syscall_info) {
      desc = "inode " inode " operation (mode: " mode ", owner: " owner ":" group ")";
    } else {
      desc = "inode " inode " operation (mode: " mode ", owner: " owner ":" group ")";
    }
  } else {
    desc = name " (modified, owner: " owner ":" group ")";
  }
  descriptions[desc]++;
}
END {
  if (length(descriptions) == 0) {
    print "No file modifications found today.";
  } else {
    for (desc in descriptions) {
      printf("    %4d %s\n", descriptions[desc], desc);
    }
  }
}' | sort -rn)
handle_output "$MODS" "No file modifications found today."

add_section "COMMANDS EXECUTED"
CMDS=$(grep "type=USER_CMD" "$TEMP_FILE" | awk '
  /type=USER_CMD/ {
    if (match($0, /auid=([^ ]+)/, user)) { username = user[1]; }
    else { username = "unknown"; }

    if (match($0, /cmd=([^ ]+) exe=/, cmdline)) { command = cmdline[1]; }
    else if (match($0, /cmd=([^"]+)/, cmdline)) { command = cmdline[1]; }
    else { command = "unknown"; }

    if (match($0, /cwd=([^ ]+)/, dir)) { workdir = dir[1]; }
    else { workdir = "unknown"; }

    key = username " ran \"" command "\" in " workdir;
    count[key]++;
  }
  END {
    if (length(count) == 0) {
      print "No commands executed today.";
    } else {
      for (entry in count) {
        printf("    %4d %s\n", count[entry], entry);
      }
    }
  }
' | sort -rn)
handle_output "$CMDS" "No commands executed today."

add_section "SUSPICIOUS IPs (LOGIN ATTEMPTS)"
SUSPICIOUS_IPS=$(grep -E "addr=" "$TEMP_FILE" | grep -E "res=failed|FAILED|failed" |
    grep -o 'addr=[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | sed 's/addr=//' | sort | uniq -c | sort -nr)
handle_output "$SUSPICIOUS_IPS" "No suspicious IPs detected today."

add_section "USER ACTIVITY SUMMARY"
USER_ACTIVITY=$(grep -E "auid=" "$TEMP_FILE" |
    sed -E 's/.*auid=([a-zA-Z0-9_-]+).*/   User: \1/g' | grep -v "auid=unset" | sort | uniq -c)
handle_output "$USER_ACTIVITY" "No user activity recorded today."

add_section "SUMMARY STATISTICS"
TOTAL_EVENTS=$(wc -l < "$TEMP_FILE" || echo 0)
FAILED_LOGIN_COUNT=$(grep -E "res=failed|FAILED|failed" "$TEMP_FILE" | grep -E "USER_LOGIN|USER_AUTH" | wc -l || echo 0)
echo "Total audit events today: $TOTAL_EVENTS" >> "$REPORT_FILE"
echo "Total failed login attempts: $FAILED_LOGIN_COUNT" >> "$REPORT_FILE"

# Send report and handle cleanup
mail -s "[AUDIT] Daily Audit Report - $(hostname) - $(date +%F)" "$ADMIN_EMAIL" < "$REPORT_FILE"

# Archive handling
if [ -f "/var/log/audit/daily-report-$(date -d yesterday +%Y%m%d).txt" ]; then
    gzip -9 "/var/log/audit/daily-report-$(date -d yesterday +%Y%m%d).txt"
fi

# Cleanup old reports
find /var/log/audit/ -name "daily-report-*.txt.gz" -mtime +365 -delete 2>/dev/null || true