#!/bin/bash
# Stage 5: Verify the server implements the ECHO command

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 5: ECHO command ==="

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0

# Pipe the RESP request directly into nc — never store it in $() which strips trailing \n
send_echo() {
    local cmd="$1"    # ECHO / echo / EcHo
    local word="$2"
    printf '*2\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n' "${#cmd}" "$cmd" "${#word}" "$word" \
        | nc -q 1 -W 1 127.0.0.1 6379 2>/dev/null
}

check_echo() {
    local label="$1"
    local cmd="$2"
    local word="$3"

    # Both response and expected go through $() so trailing newlines are stripped equally
    local response expected
    response=$(send_echo "$cmd" "$word")
    expected=$(printf '$%d\r\n%s\r' "${#word}" "$word")

    if [ "$response" = "$expected" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label: expected '$expected', got '$response'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# --- Test 1: basic known word ---
check_echo "ECHO hey" "ECHO" "hey"

# --- Test 2: random string (ensures response is not hardcoded) ---
RANDOM_WORD=$(cat /dev/urandom | tr -dc 'a-z' | head -c 8)
check_echo "ECHO $RANDOM_WORD (random)" "ECHO" "$RANDOM_WORD"

# --- Test 3: longer argument ---
check_echo "ECHO hello_world" "ECHO" "hello_world"

# --- Test 4: case-insensitive — lowercase ---
check_echo "echo (lowercase)" "echo" "case_test"

# --- Test 5: case-insensitive — mixed case ---
check_echo "EcHo (mixed case)" "EcHo" "case_test"

stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 5 passed."
else
    exit 1
fi
