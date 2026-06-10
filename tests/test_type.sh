#!/bin/bash
# Stage 14: Verify the TYPE command for string and missing keys

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 14: TYPE command ==="

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write RESP array to a temp file (avoids $() stripping trailing \n from \r\n)
send_cmd() {
    local tmp
    tmp=$(mktemp)
    printf '*%d\r\n' "$#" > "$tmp"
    for word in "$@"; do
        printf '$%d\r\n%s\r\n' "${#word}" "$word" >> "$tmp"
    done
    nc -q 1 -W 1 127.0.0.1 6379 < "$tmp" 2>/dev/null
    rm -f "$tmp"
}

check() {
    local label="$1" response="$2" expected="$3"
    if [ "$response" = "$expected" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected : $(printf '%s' "$expected" | cat -A)"
        fail "  got      : $(printf '%s' "$response"  | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# $() strips trailing \n, so simple string responses end with \r
expect_ok()     { printf '+OK\r'; }
expect_simple() { printf '+%s\r' "$1"; }

# ---------------------------------------------------------------------------
# Test 1: TYPE on a string key returns +string
# ---------------------------------------------------------------------------
response=$(send_cmd SET some_key foo)
check "SET some_key foo → +OK" "$response" "$(expect_ok)"

response=$(send_cmd TYPE some_key)
check "TYPE string key → +string" "$response" "$(expect_simple string)"

# ---------------------------------------------------------------------------
# Test 2: TYPE on a missing key returns +none
# ---------------------------------------------------------------------------
response=$(send_cmd TYPE missing_key)
check "TYPE missing key → +none" "$response" "$(expect_simple none)"

# ---------------------------------------------------------------------------
# Test 3: Random string key/value (ensures TYPE is not hardcoded to one key)
# ---------------------------------------------------------------------------
RAND_KEY=$(cat /dev/urandom | tr -dc 'a-z' | head -c 8)
RAND_VAL=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)

response=$(send_cmd SET "$RAND_KEY" "$RAND_VAL")
check "SET random key → +OK" "$response" "$(expect_ok)"

response=$(send_cmd TYPE "$RAND_KEY")
check "TYPE random string key → +string" "$response" "$(expect_simple string)"

# ---------------------------------------------------------------------------
# Test 4: Case-insensitive command — lowercase type
# ---------------------------------------------------------------------------
response=$(send_cmd type "$RAND_KEY")
check "type (lowercase) on string key → +string" "$response" "$(expect_simple string)"

response=$(send_cmd type definitely_missing)
check "type (lowercase) on missing key → +none" "$response" "$(expect_simple none)"

# ---------------------------------------------------------------------------
# Test 5: Case-insensitive command — mixed case TyPe
# ---------------------------------------------------------------------------
response=$(send_cmd TyPe some_key)
check "TyPe (mixed case) on string key → +string" "$response" "$(expect_simple string)"

response=$(send_cmd TyPe another_missing_key)
check "TyPe (mixed case) on missing key → +none" "$response" "$(expect_simple none)"

# ---------------------------------------------------------------------------
# Test 6: Expired string keys are reported as none
# ---------------------------------------------------------------------------
send_cmd SET expires_soon gone PX 50 > /dev/null
sleep 0.1
response=$(send_cmd TYPE expires_soon)
check "TYPE expired string key → +none" "$response" "$(expect_simple none)"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 14 passed."
else
    exit 1
fi
