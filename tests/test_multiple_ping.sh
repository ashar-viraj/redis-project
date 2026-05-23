# #!/bin/bash
# # Stage 3: Verify the server responds to multiple PINGs on the same connection

# source "$(dirname "$0")/helpers.sh"

# echo "=== Stage 3: Respond to multiple PINGs ==="

# build_server
# start_server

# PING_COUNT=3

# send_pings_raw() {
#     local count=$1
#     local input
#     input=$(printf '*1\r\n$4\r\nPING\r\n%.0s' $(seq 1 "$count"))
#     # -q 1: close 1s after stdin EOF so nc doesn't hang waiting for server
#     # -W count: stop reading after receiving 'count' responses
#     printf '%s' "$input" | nc -q 1 -W "$count" 127.0.0.1 6379 2>/dev/null
# }

# if command -v redis-cli &>/dev/null; then
#     PIPE_INPUT=$(printf '*1\r\n$4\r\nPING\r\n%.0s' $(seq 1 $PING_COUNT))
#     RAW=$(printf '%s' "$PIPE_INPUT" | nc -q 1 -W "$PING_COUNT" 127.0.0.1 6379 2>/dev/null)
# else
#     info "redis-cli not found, using raw nc test"
#     RAW=$(send_pings_raw "$PING_COUNT")
# fi

# PONG_COUNT=$(echo "$RAW" | grep -o '+PONG' | wc -l)
# if [ "$PONG_COUNT" -ge "$PING_COUNT" ]; then
#     pass "Received $PONG_COUNT PONG(s) for $PING_COUNT PING(s) on one connection"
# else
#     fail "Expected $PING_COUNT PONGs, received $PONG_COUNT (raw: $RAW)"
#     stop_server
#     exit 1
# fi

# stop_server
# echo ""
# echo "Stage 3 passed."


# ################################################################################################
#!/bin/bash
# Stage 3: Verify the server responds to multiple PINGs on the same connection

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 3: Respond to multiple PINGs ==="

build_server
start_server

PING_COUNT=3

send_pings_sequential() {
    {
        for ((i=1; i<=PING_COUNT; i++)); do
            printf '*1\r\n$4\r\nPING\r\n'
            sleep 0.1
        done
    } | nc -q 1 -W "$PING_COUNT" 127.0.0.1 6379 2>/dev/null
}

RAW=$(send_pings_sequential)

PONG_COUNT=$(echo "$RAW" | grep -o '+PONG' | wc -l)

if [ "$PONG_COUNT" -ge "$PING_COUNT" ]; then
    pass "Received $PONG_COUNT PONG(s) for $PING_COUNT PING(s) on one connection"
else
    fail "Expected $PING_COUNT PONGs, received $PONG_COUNT (raw: $RAW)"
    stop_server
    exit 1
fi

stop_server
echo ""
echo "Stage 3 passed."s