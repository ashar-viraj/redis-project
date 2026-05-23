#!/bin/bash
# Stage 1: Verify the server binds to port 6379

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 1: Bind to port 6379 ==="

build_server
start_server

# Check the process is listening on 6379
if ss -tlnp 2>/dev/null | grep -q ':6379'; then
    pass "Server is listening on port 6379"
else
    fail "Server is NOT listening on port 6379"
    stop_server
    exit 1
fi

# Try to open a raw TCP connection
if timeout 2 bash -c 'echo "" > /dev/tcp/127.0.0.1/6379' 2>/dev/null; then
    pass "TCP connection to 127.0.0.1:6379 succeeded"
else
    fail "Could not connect to 127.0.0.1:6379"
    stop_server
    exit 1
fi

stop_server
echo ""
echo "Stage 1 passed."
