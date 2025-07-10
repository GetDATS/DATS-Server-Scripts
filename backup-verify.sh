#!/bin/bash
set -euo pipefail

# Backup system verification script
# Tests all backup components without waiting for cron schedules

# Load configuration from SOC2 config files
source /usr/local/share/soc2-scripts/config/common.conf
source /usr/local/share/soc2-scripts/config/credentials.conf
source /usr/local/share/soc2-scripts/config/backup.conf

echo "=== Backup System Verification ==="
echo ""

# Test 1: AWS connectivity
echo "1. Testing AWS S3 connectivity..."
if aws s3 ls "s3://$AWS_BACKUP_BUCKET" >/dev/null 2>&1; then
    echo "   ✓ S3 bucket accessible: $AWS_BACKUP_BUCKET"
else
    echo "   ✗ Cannot access S3 bucket: $AWS_BACKUP_BUCKET"
    echo "   Check AWS credentials and bucket permissions"
    exit 1
fi

# Test 2: MariaDB connectivity
echo ""
echo "2. Testing MariaDB backup user..."
if mysql -u "$MARIADB_BACKUP_USER" -p"$MARIADB_ADMIN_PASSWORD" -e "SHOW MASTER STATUS;" >/dev/null 2>&1; then
    echo "   ✓ MariaDB backup user can connect"
    BINLOG_STATUS=$(mysql -u "$MARIADB_BACKUP_USER" -p"$MARIADB_ADMIN_PASSWORD" -e "SHOW MASTER STATUS\G" 2>/dev/null | grep File | awk '{print $2}')
    echo "   ✓ Current binary log: $BINLOG_STATUS"
else
    echo "   ✗ MariaDB backup user cannot connect"
    echo "   Check MARIADB_BACKUP_USER and password in credentials.conf"
    exit 1
fi

# Test 3: Directory permissions
echo ""
echo "3. Testing directory permissions..."
DIRS_OK=true
for dir in /var/log/backups /var/lib/backup-state; do
    if [ -d "$dir" ] && [ -w "$dir" ]; then
        echo "   ✓ $dir exists and is writable"
    else
        echo "   ✗ $dir missing or not writable"
        DIRS_OK=false
    fi
done

if [ "$DIRS_OK" = false ]; then
    echo "   Run setup steps to create required directories"
    exit 1
fi

# Test 4: Script permissions
echo ""
echo "4. Testing backup scripts..."
SCRIPTS_OK=true
for script in backup-mariadb-full backup-mariadb-binlog backup-home backup-logs backup-cleanup; do
    if [ -x "/usr/local/bin/${script}.sh" ]; then
        echo "   ✓ $script.sh is executable"
    else
        echo "   ✗ $script.sh missing or not executable"
        SCRIPTS_OK=false
    fi
done

if [ "$SCRIPTS_OK" = false ]; then
    echo "   Check backup script installation"
    exit 1
fi

# Test 5: Cron schedule
echo ""
echo "5. Testing cron schedule..."
if [ -f "/etc/cron.d/backup" ]; then
    echo "   ✓ Backup cron file exists"
    echo "   Scheduled jobs:"
    grep -v "^#" /etc/cron.d/backup | grep -v "^$" | while read -r line; do
        echo "     - $line"
    done
else
    echo "   ✗ Backup cron file missing"
    exit 1
fi

# Test 6: Datadog monitoring
echo ""
echo "6. Testing Datadog monitoring..."
if systemctl is-active --quiet datadog-agent; then
    echo "   ✓ Datadog agent is running"
    if [ -f "/etc/datadog-agent/conf.d/backup.d/conf.yaml" ]; then
        echo "   ✓ Backup monitoring configured"
    else
        echo "   ✗ Backup monitoring config missing"
    fi
else
    echo "   ✗ Datadog agent not running"
fi

# Test 7: Quick backup test
echo ""
echo "7. Running quick backup test..."
echo "   Testing binary log backup (may report 0 new logs)..."
if /usr/local/bin/backup-mariadb-binlog.sh >/dev/null 2>&1; then
    echo "   ✓ Binary log backup script runs successfully"
else
    echo "   ✗ Binary log backup script failed"
    echo "   Check /var/log/backups/mariadb-binlog.log for details"
fi

echo ""
echo "=== Verification Complete ==="
echo ""
echo "Next steps:"
echo "1. Monitor /var/log/backups/ for backup logs"
echo "2. Check email for backup notifications"
echo "3. Verify backups appear in S3 after cron runs"
echo "4. Review Datadog dashboard for backup metrics"
echo ""
echo "Backup schedule:"
echo "- MariaDB binary logs: Every 15 minutes"
echo "- MariaDB full backup: Daily at 2:00 AM UTC"
echo "- Home directory: Daily at 3:00 AM UTC"
echo "- Log archives: Daily at 3:30 AM UTC"
echo "- Cleanup: Weekly on Sundays at 4:00 AM UTC"