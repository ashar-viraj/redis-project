#!/bin/bash
# Stage 8: Verify the RPUSH command (create/append list, return element count)

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 8: RPUSH command ==="

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

# Expected response builders.
# $() strips the trailing \n, so the response arrives as "...\r" — builders match that.
expect_int()  { printf ':%d\r' "$1"; }          # RESP integer  :N\r\n  → :N\r
expect_bulk() { printf '$%d\r\n%s\r' "${#1}" "$1"; }  # RESP bulk string
expect_null() { printf '$-1\r'; }               # null bulk string

# ---------------------------------------------------------------------------
# Test 1: RPUSH single element to a new list → returns :1
# ---------------------------------------------------------------------------
response=$(send_cmd RPUSH mylist foo)
check "RPUSH new list, 1 element → :1" "$response" "$(expect_int 1)"

# ---------------------------------------------------------------------------
# Test 2: RPUSH a second element to existing list → returns :2
# ---------------------------------------------------------------------------
response=$(send_cmd RPUSH mylist bar)
check "RPUSH existing list, 2nd element → :2" "$response" "$(expect_int 2)"

# ---------------------------------------------------------------------------
# Test 3: RPUSH a third element → returns :3
# ---------------------------------------------------------------------------
response=$(send_cmd RPUSH mylist baz)
check "RPUSH existing list, 3rd element → :3" "$response" "$(expect_int 3)"

# ---------------------------------------------------------------------------
# Test 4: RPUSH multiple elements in one call → returns total count
# ---------------------------------------------------------------------------
response=$(send_cmd RPUSH multilist a b c)
check "RPUSH 3 elements at once to new list → :3" "$response" "$(expect_int 3)"

response=$(send_cmd RPUSH multilist d e)
check "RPUSH 2 more elements to existing list → :5" "$response" "$(expect_int 5)"

# ---------------------------------------------------------------------------
# Test 5: Random key/value (ensures nothing is hardcoded)
# ---------------------------------------------------------------------------
RAND_KEY=$(cat /dev/urandom | tr -dc 'a-z' | head -c 8)
RAND_VAL=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 10)

response=$(send_cmd RPUSH "$RAND_KEY" "$RAND_VAL")
check "RPUSH random key/value → :1" "$response" "$(expect_int 1)"

response=$(send_cmd RPUSH "$RAND_KEY" second)
check "RPUSH second to random key → :2" "$response" "$(expect_int 2)"

# ---------------------------------------------------------------------------
# Test 6: Case-insensitive command — lowercase rpush
# ---------------------------------------------------------------------------
response=$(send_cmd rpush lc_list alpha)
check "rpush (lowercase) → :1" "$response" "$(expect_int 1)"

# ---------------------------------------------------------------------------
# Test 7: Case-insensitive command — mixed case rPuSh
# ---------------------------------------------------------------------------
response=$(send_cmd rPuSh mc_list alpha)
check "rPuSh (mixed case) → :1" "$response" "$(expect_int 1)"

# ---------------------------------------------------------------------------
# Test 8: Two independent lists don't share counts
# ---------------------------------------------------------------------------
send_cmd RPUSH listA x > /dev/null
send_cmd RPUSH listA y > /dev/null
response=$(send_cmd RPUSH listB z)
check "Independent lists: RPUSH listB starts count at 1" "$response" "$(expect_int 1)"

response=$(send_cmd RPUSH listA w)
check "Independent lists: RPUSH listA continues its own count → :3" "$response" "$(expect_int 3)"

# ---------------------------------------------------------------------------
# Test 9: RPUSH multiple elements at once — count accumulates correctly
# ---------------------------------------------------------------------------
send_cmd RPUSH accum one > /dev/null           # count = 1
send_cmd RPUSH accum two three > /dev/null     # count = 3
response=$(send_cmd RPUSH accum four five six)
check "RPUSH accumulated count → :6" "$response" "$(expect_int 6)"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 8 passed."
else
    exit 1
fi
