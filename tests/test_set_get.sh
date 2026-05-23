#!/bin/bash
# Stage 6: Verify the server implements SET and GET commands

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 6: SET & GET commands ==="

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Low-level helpers
# ---------------------------------------------------------------------------

# Send a RESP array command built from individual words, return raw response.
# Writes to a temp file to avoid $() stripping trailing \n from \r\n sequences.
send_cmd() {
    local tmp
    tmp=$(mktemp)
    local count=$#
    printf '*%d\r\n' "$count" > "$tmp"
    for word in "$@"; do
        printf '$%d\r\n%s\r\n' "${#word}" "$word" >> "$tmp"
    done
    nc -q 1 -W 1 127.0.0.1 6379 < "$tmp" 2>/dev/null
    rm -f "$tmp"
}

# Check helper: compare response to expected, print pass/fail
check() {
    local label="$1"
    local response="$2"
    local expected="$3"
    if [ "$response" = "$expected" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected : $(printf '%s' "$expected" | cat -A)"
        fail "  got      : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# ---------------------------------------------------------------------------
# Expected response builders
# ---------------------------------------------------------------------------

# +OK\r\n — $() strips trailing \n, leaving +OK\r
expect_ok() { printf '+OK\r'; }

# $<len>\r\n<val>\r\n — $() strips trailing \n, leaving ...\r
expect_bulk() { printf '$%d\r\n%s\r' "${#1}" "$1"; }

# Null bulk string $-1\r\n — $() strips \n, leaving $-1\r
expect_null() { printf '$-1\r'; }

# ---------------------------------------------------------------------------
# Test 1: Basic SET → +OK
# ---------------------------------------------------------------------------
response=$(send_cmd SET foo bar)
check "SET foo bar → +OK" "$response" "$(expect_ok)"

# ---------------------------------------------------------------------------
# Test 2: Basic GET of existing key → bulk string
# ---------------------------------------------------------------------------
response=$(send_cmd GET foo)
check "GET foo → bar" "$response" "$(expect_bulk bar)"

# ---------------------------------------------------------------------------
# Test 3: GET of non-existent key → null bulk string
# ---------------------------------------------------------------------------
response=$(send_cmd GET doesnotexist)
check "GET missing key → null bulk" "$response" "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 4: Random key/value (ensures nothing is hardcoded)
# ---------------------------------------------------------------------------
RAND_KEY=$(cat /dev/urandom | tr -dc 'a-z' | head -c 8)
RAND_VAL=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)

response=$(send_cmd SET "$RAND_KEY" "$RAND_VAL")
check "SET random key → +OK" "$response" "$(expect_ok)"

response=$(send_cmd GET "$RAND_KEY")
check "GET random key → correct value" "$response" "$(expect_bulk "$RAND_VAL")"

# ---------------------------------------------------------------------------
# Test 5: Overwrite an existing key — GET should return new value
# ---------------------------------------------------------------------------
send_cmd SET mykey first  > /dev/null
send_cmd SET mykey second > /dev/null
response=$(send_cmd GET mykey)
check "SET overwrites → GET returns new value" "$response" "$(expect_bulk second)"

# ---------------------------------------------------------------------------
# Test 6: Case-insensitive commands — set / get (lowercase)
# ---------------------------------------------------------------------------
response=$(send_cmd set casekey casevalue)
check "set (lowercase) → +OK" "$response" "$(expect_ok)"

response=$(send_cmd get casekey)
check "get (lowercase) → correct value" "$response" "$(expect_bulk casevalue)"

# ---------------------------------------------------------------------------
# Test 7: Case-insensitive commands — SeT / GeT (mixed case)
# ---------------------------------------------------------------------------
response=$(send_cmd SeT mixedkey mixedvalue)
check "SeT (mixed case) → +OK" "$response" "$(expect_ok)"

response=$(send_cmd GeT mixedkey)
check "GeT (mixed case) → correct value" "$response" "$(expect_bulk mixedvalue)"

# ---------------------------------------------------------------------------
# Test 8: Value with spaces (sent as a single bulk string argument)
# ---------------------------------------------------------------------------
response=$(send_cmd SET spacekey "hello world")
check "SET value with spaces → +OK" "$response" "$(expect_ok)"

response=$(send_cmd GET spacekey)
check "GET value with spaces → correct value" "$response" "$(expect_bulk "hello world")"

# ---------------------------------------------------------------------------
# Test 9: Multiple independent keys don't interfere with each other
# ---------------------------------------------------------------------------
send_cmd SET keyA valueA > /dev/null
send_cmd SET keyB valueB > /dev/null

resp_a=$(send_cmd GET keyA)
resp_b=$(send_cmd GET keyB)

check "GET keyA doesn't return keyB's value" "$resp_a" "$(expect_bulk valueA)"
check "GET keyB doesn't return keyA's value" "$resp_b" "$(expect_bulk valueB)"

# ---------------------------------------------------------------------------
# Test 10: Key re-used after overwrite — old value must not reappear
# ---------------------------------------------------------------------------
send_cmd SET reuse old > /dev/null
send_cmd SET reuse new > /dev/null
response=$(send_cmd GET reuse)
check "Overwritten key never returns old value" "$response" "$(expect_bulk new)"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 6 passed."
else
    exit 1
fi
