#!/bin/bash

# Calculate optimal PHP-FPM settings based on available system resources
# This script prevents both under-utilization of large servers and over-allocation on small ones

set -euo pipefail

# Get system resources
TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
CPU_CORES=$(nproc)

# Resource allocation strategy:
# - Apache: 25% of RAM (handled by separate script)
# - PHP-FPM: 25% of RAM (PHP application processes)
# - MariaDB: 40% of RAM (database operations)
# - System/other: 10% of RAM (OS, monitoring, etc.)

AVAILABLE_FOR_PHP=$((TOTAL_RAM_GB * 25 / 100))
[ $AVAILABLE_FOR_PHP -lt 1 ] && AVAILABLE_FOR_PHP=1  # Minimum 1GB for PHP

# Memory per PHP-FPM process (adjust based on your application complexity)
# - Simple apps: 64MB per process
# - Complex apps with frameworks: 128-256MB per process
MEMORY_PER_PROCESS=128  # MB - reasonable default for most PHP applications

# Calculate max_children (total PHP processes)
MAX_CHILDREN=$((AVAILABLE_FOR_PHP * 1024 / MEMORY_PER_PROCESS))

# Apply sensible caps - even massive servers don't need unlimited PHP processes
[ $MAX_CHILDREN -gt 500 ] && MAX_CHILDREN=500  # Cap at 500 for sanity
[ $MAX_CHILDREN -lt 5 ] && MAX_CHILDREN=5      # Minimum of 5

# Calculate process pool management settings
START_SERVERS=$((MAX_CHILDREN * 25 / 100))     # Start with 25% of max capacity
MIN_SPARE=$((MAX_CHILDREN * 15 / 100))         # Keep 15% as minimum spare
MAX_SPARE=$((MAX_CHILDREN * 75 / 100))         # Allow up to 75% as maximum spare

# Ensure sensible minimums
[ $START_SERVERS -lt 2 ] && START_SERVERS=2
[ $MIN_SPARE -lt 1 ] && MIN_SPARE=1
[ $MAX_SPARE -lt 3 ] && MAX_SPARE=3

# Ensure max_spare doesn't exceed max_children
[ $MAX_SPARE -gt $MAX_CHILDREN ] && MAX_SPARE=$MAX_CHILDREN

# Calculate max_requests (process recycling to prevent memory leaks)
MAX_REQUESTS=$((MAX_CHILDREN * 10))  # Each process handles 10x the pool size over its lifetime
[ $MAX_REQUESTS -lt 500 ] && MAX_REQUESTS=500      # Minimum recycling
[ $MAX_REQUESTS -gt 10000 ] && MAX_REQUESTS=10000  # Maximum before recycling

# Check if we should output values only (for use in other scripts)
if [[ "${1:-}" == "--values-only" ]]; then
    # Output shell variables for eval in documentation
    cat << EOF
MAX_CHILDREN=${MAX_CHILDREN}
START_SERVERS=${START_SERVERS}
MIN_SPARE_SERVERS=${MIN_SPARE}
MAX_SPARE_SERVERS=${MAX_SPARE}
MAX_REQUESTS=${MAX_REQUESTS}
EOF
    exit 0
fi

# Output the calculated PHP-FPM pool configuration
cat << EOF
# Calculated PHP-FPM pool configuration for ${TOTAL_RAM_GB}GB RAM, ${CPU_CORES} CPU cores
# PHP-FPM allocated: ${AVAILABLE_FOR_PHP}GB RAM (25% of total)
# Memory per process: ${MEMORY_PER_PROCESS}MB

[www]
user = www-data
group = www-data

; Unix socket communication (faster than TCP)
listen = /run/php/php8.4-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

; Process management - calculated for optimal resource usage
pm = dynamic
pm.max_children = ${MAX_CHILDREN}
pm.start_servers = ${START_SERVERS}
pm.min_spare_servers = ${MIN_SPARE}
pm.max_spare_servers = ${MAX_SPARE}
pm.max_requests = ${MAX_REQUESTS}

; Monitoring and logging
pm.status_path = /status
ping.path = /ping
slowlog = /var/log/php/fpm-slow.log
request_slowlog_timeout = 10s
access.log = /var/log/php/fpm-access.log

; Security - terminate long-running requests
request_terminate_timeout = 60s
EOF

# Also output a summary for the administrator
echo ""
echo "; Summary:"
echo "; - Server resources: ${TOTAL_RAM_GB}GB RAM, ${CPU_CORES} CPU cores"
echo "; - PHP-FPM allocation: ${AVAILABLE_FOR_PHP}GB RAM (${MEMORY_PER_PROCESS}MB per process)"
echo "; - Process capacity: ${MAX_CHILDREN} max processes"
echo "; - Process pool: ${START_SERVERS} initial, ${MIN_SPARE}-${MAX_SPARE} spare processes"
echo "; - Process recycling: every ${MAX_REQUESTS} requests"
echo "; - Estimated concurrent PHP requests: ~${MAX_CHILDREN}"