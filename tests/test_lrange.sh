#!/bin/bash
# Stage 9 & 10: Verify LRANGE with positive and negative indexes

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 9/10: LRANGE command (positive & negative indexes) ==="

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write RESP array to temp file — avoids $() stripping \r\n
# Uses timeout 3 + -q 1 (no -W) so multi-element array responses arrive fully
send_cmd() {
    local tmp
    tmp=$(mktemp)
    printf '*%d\r\n' "$#" > "$tmp"
    for word in "$@"; do
        printf '$%d\r\n%s\r\n' "${#word}" "$word" >> "$tmp"
    done
    timeout 3 nc -q 1 127.0.0.1 6379 < "$tmp" 2>/dev/null
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

# Build expected RESP array.
# $() strips the final \n, so the last byte of the response is \r, not \n.
# For an empty array (*0\r\n) → $() strips \n → *0\r
expect_empty_array() {
    printf '*0\r'
}

# expect_array elem1 elem2 ...
# Builds the full RESP array string that $() will produce (trailing \n stripped).
expect_array() {
    if [ $# -eq 0 ]; then
        expect_empty_array
        return
    fi
    local count=$# i=1
    printf '*%d\r\n' "$count"
    for word in "$@"; do
        if [ "$i" -eq "$count" ]; then
            # Last element: no trailing \n (stripped by $())
            printf '$%d\r\n%s\r' "${#word}" "$word"
        else
            printf '$%d\r\n%s\r\n' "${#word}" "$word"
        fi
        i=$((i + 1))
    done
}

# ---------------------------------------------------------------------------
# Setup: build the reference list  [a, b, c, d, e]
# ---------------------------------------------------------------------------
send_cmd RPUSH mylist a b c d e > /dev/null

# ---------------------------------------------------------------------------
# Positive index tests
# ---------------------------------------------------------------------------

# Test 1: full range
response=$(send_cmd LRANGE mylist 0 4)
check "LRANGE 0 4 → [a,b,c,d,e]" "$response" "$(expect_array a b c d e)"

# Test 2: first two elements
response=$(send_cmd LRANGE mylist 0 1)
check "LRANGE 0 1 → [a,b]" "$response" "$(expect_array a b)"

# Test 3: middle slice
response=$(send_cmd LRANGE mylist 2 4)
check "LRANGE 2 4 → [c,d,e]" "$response" "$(expect_array c d e)"

# Test 4: single element (first)
response=$(send_cmd LRANGE mylist 0 0)
check "LRANGE 0 0 → [a]" "$response" "$(expect_array a)"

# Test 5: single element (last by exact index)
response=$(send_cmd LRANGE mylist 4 4)
check "LRANGE 4 4 → [e]" "$response" "$(expect_array e)"

# Test 6: stop index beyond length — clamped to last element
response=$(send_cmd LRANGE mylist 2 100)
check "LRANGE 2 100 (stop > len) → [c,d,e]" "$response" "$(expect_array c d e)"

response=$(send_cmd LRANGE mylist 0 999)
check "LRANGE 0 999 (stop >> len) → [a,b,c,d,e]" "$response" "$(expect_array a b c d e)"

# Test 7: start index >= length → empty array
response=$(send_cmd LRANGE mylist 5 10)
check "LRANGE 5 10 (start >= len) → []" "$response" "$(expect_empty_array)"

response=$(send_cmd LRANGE mylist 100 200)
check "LRANGE 100 200 (start >> len) → []" "$response" "$(expect_empty_array)"

# Test 8: start > stop → empty array
response=$(send_cmd LRANGE mylist 3 1)
check "LRANGE 3 1 (start > stop) → []" "$response" "$(expect_empty_array)"

# Test 9: non-existent list → empty array
response=$(send_cmd LRANGE nosuchlist 0 5)
check "LRANGE on non-existent key → []" "$response" "$(expect_empty_array)"

# ---------------------------------------------------------------------------
# Negative index tests
# ---------------------------------------------------------------------------

# Test 10: -1 is last element
response=$(send_cmd LRANGE mylist -1 -1)
check "LRANGE -1 -1 → [e]" "$response" "$(expect_array e)"

# Test 11: -2 to -1 → last two
response=$(send_cmd LRANGE mylist -2 -1)
check "LRANGE -2 -1 → [d,e]" "$response" "$(expect_array d e)"

# Test 12: 0 to -1 → whole list
response=$(send_cmd LRANGE mylist 0 -1)
check "LRANGE 0 -1 → [a,b,c,d,e]" "$response" "$(expect_array a b c d e)"

# Test 13: 0 to -3 → all but last two
response=$(send_cmd LRANGE mylist 0 -3)
check "LRANGE 0 -3 → [a,b,c]" "$response" "$(expect_array a b c)"

# Test 14: -5 to -1 → whole list (negative start == first element)
response=$(send_cmd LRANGE mylist -5 -1)
check "LRANGE -5 -1 → [a,b,c,d,e]" "$response" "$(expect_array a b c d e)"

# Test 15: mixed — positive start, negative stop
response=$(send_cmd LRANGE mylist 2 -1)
check "LRANGE 2 -1 → [c,d,e]" "$response" "$(expect_array c d e)"

response=$(send_cmd LRANGE mylist 1 -2)
check "LRANGE 1 -2 → [b,c,d]" "$response" "$(expect_array b c d)"

# Test 16: mixed — negative start, positive stop
response=$(send_cmd LRANGE mylist -3 4)
check "LRANGE -3 4 → [c,d,e]" "$response" "$(expect_array c d e)"

# Test 17: negative start out of range → treated as 0
response=$(send_cmd LRANGE mylist -100 -1)
check "LRANGE -100 -1 (neg start OOB) → [a,b,c,d,e]" "$response" "$(expect_array a b c d e)"

response=$(send_cmd LRANGE mylist -100 2)
check "LRANGE -100 2 (neg start OOB) → [a,b,c]" "$response" "$(expect_array a b c)"

# Test 18: negative stop resolves to before start → empty array
response=$(send_cmd LRANGE mylist 3 -4)
check "LRANGE 3 -4 (resolves to 3..1) → []" "$response" "$(expect_empty_array)"

# Test 19: stop also out-of-range negative (-99+5=-94, still <0)
# start=0 (clamped), stop=-94 (still negative) → start > stop → empty
response=$(send_cmd LRANGE mylist -100 -99)
check "LRANGE -100 -99 (stop still negative after resolve) → []" "$response" "$(expect_empty_array)"

# ---------------------------------------------------------------------------
# Case-insensitive command
# ---------------------------------------------------------------------------
response=$(send_cmd lrange mylist 0 1)
check "lrange (lowercase) → [a,b]" "$response" "$(expect_array a b)"

response=$(send_cmd LrAnGe mylist 0 1)
check "LrAnGe (mixed case) → [a,b]" "$response" "$(expect_array a b)"

# ---------------------------------------------------------------------------
# Random key/value (ensures nothing is hardcoded)
# ---------------------------------------------------------------------------
RAND_KEY=$(cat /dev/urandom | tr -dc 'a-z' | head -c 8)
RAND_V1=$(cat /dev/urandom | tr -dc 'a-z' | head -c 5)
RAND_V2=$(cat /dev/urandom | tr -dc 'a-z' | head -c 5)
RAND_V3=$(cat /dev/urandom | tr -dc 'a-z' | head -c 5)

send_cmd RPUSH "$RAND_KEY" "$RAND_V1" "$RAND_V2" "$RAND_V3" > /dev/null

response=$(send_cmd LRANGE "$RAND_KEY" 0 -1)
check "LRANGE random list 0 -1 → all 3 elements" "$response" \
    "$(expect_array "$RAND_V1" "$RAND_V2" "$RAND_V3")"

response=$(send_cmd LRANGE "$RAND_KEY" -1 -1)
check "LRANGE random list -1 -1 → last element" "$response" \
    "$(expect_array "$RAND_V3")"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 9/10 passed."
else
    exit 1
fi
