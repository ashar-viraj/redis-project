#!/bin/bash
# Stage 4: Verify the server handles multiple concurrent clients

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 4: Concurrent clients ==="

build_server
start_server

CLIENT_COUNT=5   # send this many simultaneous connections
TMPDIR_LOCAL=$(mktemp -d)

# Launch CLIENT_COUNT connections in parallel, each sending one PING
for i in $(seq 1 $CLIENT_COUNT); do
    (
        printf '*1\r\n$4\r\nPING\r\n' \
            | timeout 3 nc -q 1 -W 1 127.0.0.1 6379 2>/dev/null \
            > "$TMPDIR_LOCAL/resp_$i"
    ) &
done

# Wait for all background clients (capped at 5s total)
timeout 5 bash -c 'wait' 2>/dev/null || wait 2>/dev/null || true

# Count how many got a valid +PONG response
PONG_COUNT=0
FAILED_CLIENTS=()
for i in $(seq 1 $CLIENT_COUNT); do
    if grep -q '+PONG' "$TMPDIR_LOCAL/resp_$i" 2>/dev/null; then
        PONG_COUNT=$((PONG_COUNT + 1))
    else
        FAILED_CLIENTS+=("client $i")
    fi
done

rm -rf "$TMPDIR_LOCAL"

if [ "$PONG_COUNT" -eq "$CLIENT_COUNT" ]; then
    pass "All $CLIENT_COUNT concurrent clients received PONG"
else
    fail "$PONG_COUNT/$CLIENT_COUNT clients got PONG"
    for c in "${FAILED_CLIENTS[@]}"; do
        fail "  No response from $c"
    done
    stop_server
    exit 1
fi

stop_server
echo ""
echo "Stage 4 passed."
