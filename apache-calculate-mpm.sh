#!/bin/bash

# Calculate optimal Apache MPM Event settings based on available system resources
# This script prevents both under-utilization of large servers and over-allocation on small ones

set -euo pipefail

# Get system resources
TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
CPU_CORES=$(nproc)

# Resource allocation strategy:
# - Apache: 25% of RAM (threads + connection handling)
# - PHP-FPM: 25% of RAM (will be calculated in separate script)
# - MariaDB: 40% of RAM (database operations)
# - System/other: 10% of RAM (OS, monitoring, etc.)

AVAILABLE_FOR_APACHE=$((TOTAL_RAM_GB * 25 / 100))
[ $AVAILABLE_FOR_APACHE -lt 1 ] && AVAILABLE_FOR_APACHE=1  # Minimum 1GB for Apache

# Memory per thread (Apache threads are lightweight compared to PHP processes)
MEMORY_PER_THREAD=8  # MB - Apache threads use much less memory than PHP-FPM processes

# Calculate MaxRequestWorkers (total concurrent connections)
MAX_REQUEST_WORKERS=$((AVAILABLE_FOR_APACHE * 1024 / MEMORY_PER_THREAD))

# Apply sensible caps - even massive servers don't need unlimited connections
[ $MAX_REQUEST_WORKERS -gt 1000 ] && MAX_REQUEST_WORKERS=1000  # Cap at 1000 for sanity
[ $MAX_REQUEST_WORKERS -lt 50 ] && MAX_REQUEST_WORKERS=50      # Minimum of 50

# Calculate ThreadsPerChild based on CPU cores (but not too high)
THREADS_PER_CHILD=$((CPU_CORES * 8))  # 8 threads per core is reasonable
[ $THREADS_PER_CHILD -gt 64 ] && THREADS_PER_CHILD=64    # Cap at 64
[ $THREADS_PER_CHILD -lt 16 ] && THREADS_PER_CHILD=16    # Minimum of 16

# Calculate StartServers based on MaxRequestWorkers and ThreadsPerChild
START_SERVERS=$((MAX_REQUEST_WORKERS / THREADS_PER_CHILD / 4))  # Start with 25% capacity
[ $START_SERVERS -lt 2 ] && START_SERVERS=2  # Minimum 2 processes
[ $START_SERVERS -gt 8 ] && START_SERVERS=8  # Maximum 8 initial processes

# Calculate spare thread pool (25% and 75% of total capacity)
MIN_SPARE_THREADS=$((MAX_REQUEST_WORKERS * 15 / 100))
MAX_SPARE_THREADS=$((MAX_REQUEST_WORKERS * 35 / 100))

# Ensure minimums for spare threads
[ $MIN_SPARE_THREADS -lt 10 ] && MIN_SPARE_THREADS=10
[ $MAX_SPARE_THREADS -lt 25 ] && MAX_SPARE_THREADS=25

# Connection recycling (prevent memory leaks in long-running processes)
MAX_CONNECTIONS_PER_CHILD=$((MAX_REQUEST_WORKERS * 100))  # Each child handles 100x the total capacity over its lifetime
[ $MAX_CONNECTIONS_PER_CHILD -lt 1000 ] && MAX_CONNECTIONS_PER_CHILD=1000   # Minimum recycling
[ $MAX_CONNECTIONS_PER_CHILD -gt 50000 ] && MAX_CONNECTIONS_PER_CHILD=50000 # Maximum before recycling

# Check if we should output values only (for use in other scripts)
if [[ "${1:-}" == "--values-only" ]]; then
    # Output shell variables for eval in documentation
    cat << EOF
START_SERVERS=${START_SERVERS}
MIN_SPARE_THREADS=${MIN_SPARE_THREADS}
MAX_SPARE_THREADS=${MAX_SPARE_THREADS}
THREADS_PER_CHILD=${THREADS_PER_CHILD}
MAX_REQUEST_WORKERS=${MAX_REQUEST_WORKERS}
MAX_CONNECTIONS_PER_CHILD=${MAX_CONNECTIONS_PER_CHILD}
EOF
    exit 0
fi

# Output the calculated configuration
cat << EOF
# Calculated Apache MPM Event configuration for ${TOTAL_RAM_GB}GB RAM, ${CPU_CORES} CPU cores
# Apache allocated: ${AVAILABLE_FOR_APACHE}GB RAM (25% of total)
# Target capacity: ${MAX_REQUEST_WORKERS} concurrent connections

<IfModule mpm_event_module>
   StartServers            ${START_SERVERS}
   MinSpareThreads         ${MIN_SPARE_THREADS}
   MaxSpareThreads         ${MAX_SPARE_THREADS}
   ThreadLimit             ${THREADS_PER_CHILD}
   ThreadsPerChild         ${THREADS_PER_CHILD}
   MaxRequestWorkers       ${MAX_REQUEST_WORKERS}
   MaxConnectionsPerChild  ${MAX_CONNECTIONS_PER_CHILD}
</IfModule>
EOF

# Also output a summary for the administrator
echo ""
echo "# Summary:"
echo "# - Server resources: ${TOTAL_RAM_GB}GB RAM, ${CPU_CORES} CPU cores"
echo "# - Apache allocation: ${AVAILABLE_FOR_APACHE}GB RAM (${MEMORY_PER_THREAD}MB per thread)"
echo "# - Concurrent capacity: ${MAX_REQUEST_WORKERS} connections"
echo "# - Process model: ${START_SERVERS} initial processes, ${THREADS_PER_CHILD} threads each"
echo "# - Thread pool: ${MIN_SPARE_THREADS}-${MAX_SPARE_THREADS} spare threads"
echo "# - Process recycling: every ${MAX_CONNECTIONS_PER_CHILD} connections"