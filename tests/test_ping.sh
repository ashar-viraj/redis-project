#!/bin/bash
# Stage 2: Verify the server responds to a single PING with PONG

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 2: Respond to PING ==="

build_server
start_server

# redis-cli sends PING in RESP format and expects +PONG back
if command -v redis-cli &>/dev/null; then
    RESPONSE=$(redis-cli -p 6379 PING 2>/dev/null)
    if [ "$RESPONSE" = "PONG" ]; then
        pass "redis-cli PING returned: $RESPONSE"
    else
        fail "Expected PONG, got: '$RESPONSE'"
        stop_server
        exit 1
    fi
else
    info "redis-cli not found, using raw socket test"
    # Send RESP-encoded PING manually and read the raw reply
    RESPONSE=$(printf '*1\r\n$4\r\nPING\r\n' | nc -q 1 -W 1 127.0.0.1 6379 2>/dev/null)
    if echo "$RESPONSE" | grep -q '+PONG'; then
        pass "Raw socket PING returned: $RESPONSE"
    else
        fail "Expected +PONG in response, got: '$RESPONSE'"
        stop_server
        exit 1
    fi
fi

stop_server
echo ""
echo "Stage 2 passed."
