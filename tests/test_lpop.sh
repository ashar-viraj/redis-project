#!/bin/bash
# Stage 12: Verify LPOP with a count argument (removes N elements from the front)

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 12: LPOP (multi-element) ==="

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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

# $() strips trailing \n → responses end with \r
expect_int()         { printf ':%d\r' "$1"; }
expect_bulk()        { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_null()        { printf '$-1\r'; }
expect_empty_array() { printf '*0\r'; }

# RESP array; last element ends with \r (no trailing \n after $())
expect_array() {
    [ $# -eq 0 ] && { expect_empty_array; return; }
    local count=$# i=1
    printf '*%d\r\n' "$count"
    for word in "$@"; do
        if [ "$i" -eq "$count" ]; then
            printf '$%d\r\n%s\r' "${#word}" "$word"
        else
            printf '$%d\r\n%s\r\n' "${#word}" "$word"
        fi
        i=$((i + 1))
    done
}

# ---------------------------------------------------------------------------
# Test 1: Basic LPOP 2 from a 5-element list — returns first 2 elements
# ---------------------------------------------------------------------------
send_cmd RPUSH lpop_list one two three four five > /dev/null

response=$(send_cmd LPOP lpop_list 2)
check "LPOP 2 → [one,two]" "$response" "$(expect_array one two)"

# Remaining list should be [three, four, five]
response=$(send_cmd LRANGE lpop_list 0 -1)
check "LRANGE after LPOP 2 → [three,four,five]" "$response" \
    "$(expect_array three four five)"

# ---------------------------------------------------------------------------
# Test 2: LPOP 1 with count arg — returns a 1-element RESP array (not bulk string)
# ---------------------------------------------------------------------------
response=$(send_cmd LPOP lpop_list 1)
check "LPOP 1 (count arg) → [three]" "$response" "$(expect_array three)"

response=$(send_cmd LRANGE lpop_list 0 -1)
check "LRANGE after LPOP 1 → [four,five]" "$response" "$(expect_array four five)"

# ---------------------------------------------------------------------------
# Test 3: LPOP count exactly equal to remaining length — removes all
# ---------------------------------------------------------------------------
response=$(send_cmd LPOP lpop_list 2)
check "LPOP 2 (all remaining) → [four,five]" "$response" "$(expect_array four five)"

# List is now empty; LRANGE should return empty array
response=$(send_cmd LRANGE lpop_list 0 -1)
check "LRANGE on empty/gone list → []" "$response" "$(expect_empty_array)"

# ---------------------------------------------------------------------------
# Test 4: LPOP count greater than list length — returns all elements
# ---------------------------------------------------------------------------
send_cmd RPUSH overflow_list alpha beta gamma > /dev/null

response=$(send_cmd LPOP overflow_list 100)
check "LPOP 100 on 3-elem list → [alpha,beta,gamma]" "$response" \
    "$(expect_array alpha beta gamma)"

response=$(send_cmd LRANGE overflow_list 0 -1)
check "LRANGE after LPOP all → []" "$response" "$(expect_empty_array)"

# ---------------------------------------------------------------------------
# Test 5: LPOP 0 — returns empty array (no elements removed)
# ---------------------------------------------------------------------------
send_cmd RPUSH zero_list x y z > /dev/null

response=$(send_cmd LPOP zero_list 0)
check "LPOP 0 → empty array" "$response" "$(expect_empty_array)"

# List should be unchanged
response=$(send_cmd LRANGE zero_list 0 -1)
check "LRANGE unchanged after LPOP 0 → [x,y,z]" "$response" "$(expect_array x y z)"

# ---------------------------------------------------------------------------
# Test 6: LPOP on non-existent key → null bulk string
# ---------------------------------------------------------------------------
response=$(send_cmd LPOP nosuchkey 3)
check "LPOP on non-existent key → null" "$response" "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 7: Interleave LPUSH + RPUSH, then LPOP — verify correct front
#
# LPUSH mixed_list c b a  →  prepend c → [c], b → [b,c], a → [a,b,c]
# RPUSH mixed_list d e    →  append → [a,b,c,d,e]
# LPOP mixed_list 3       →  remove [a,b,c], leaving [d,e]
# ---------------------------------------------------------------------------
send_cmd LPUSH mixed_list c b a > /dev/null
send_cmd RPUSH mixed_list d e   > /dev/null

response=$(send_cmd LRANGE mixed_list 0 -1)
check "Setup mixed list → [a,b,c,d,e]" "$response" "$(expect_array a b c d e)"

response=$(send_cmd LPOP mixed_list 3)
check "LPOP 3 from mixed list → [a,b,c]" "$response" "$(expect_array a b c)"

response=$(send_cmd LRANGE mixed_list 0 -1)
check "LRANGE after LPOP 3 → [d,e]" "$response" "$(expect_array d e)"

# ---------------------------------------------------------------------------
# Test 8: Multiple sequential LPOPs — state is consistent across calls
# ---------------------------------------------------------------------------
send_cmd RPUSH seq_list p q r s t > /dev/null

send_cmd LPOP seq_list 2 > /dev/null   # removes p, q → [r,s,t]

response=$(send_cmd LPOP seq_list 2)   # removes r, s → [t]
check "2nd LPOP 2 → [r,s]" "$response" "$(expect_array r s)"

response=$(send_cmd LRANGE seq_list 0 -1)
check "LRANGE after 2 sequential LPOPs → [t]" "$response" "$(expect_array t)"

response=$(send_cmd LPOP seq_list 5)   # only 1 element left
check "LPOP 5 on 1-elem list → [t]" "$response" "$(expect_array t)"

# ---------------------------------------------------------------------------
# Test 9: Random key/value (ensures nothing is hardcoded)
# ---------------------------------------------------------------------------
RAND_KEY=$(cat /dev/urandom | tr -dc 'a-z' | head -c 8)
RAND_V1=$(cat /dev/urandom | tr -dc 'a-z' | head -c 5)
RAND_V2=$(cat /dev/urandom | tr -dc 'a-z' | head -c 5)
RAND_V3=$(cat /dev/urandom | tr -dc 'a-z' | head -c 5)

send_cmd RPUSH "$RAND_KEY" "$RAND_V1" "$RAND_V2" "$RAND_V3" > /dev/null

response=$(send_cmd LPOP "$RAND_KEY" 2)
check "LPOP 2 random → [v1,v2]" "$response" "$(expect_array "$RAND_V1" "$RAND_V2")"

response=$(send_cmd LRANGE "$RAND_KEY" 0 -1)
check "LRANGE random after LPOP 2 → [v3]" "$response" "$(expect_array "$RAND_V3")"

# ---------------------------------------------------------------------------
# Test 10: Case-insensitive — lowercase lpop
# ---------------------------------------------------------------------------
send_cmd RPUSH lc_list foo bar baz > /dev/null

response=$(send_cmd lpop lc_list 2)
check "lpop (lowercase) 2 → [foo,bar]" "$response" "$(expect_array foo bar)"

# ---------------------------------------------------------------------------
# Test 11: Case-insensitive — mixed case lPoP
# ---------------------------------------------------------------------------
send_cmd RPUSH mc_list one two three > /dev/null

response=$(send_cmd lPoP mc_list 2)
check "lPoP (mixed case) 2 → [one,two]" "$response" "$(expect_array one two)"

# ---------------------------------------------------------------------------
# Test 12: Two independent lists — LPOP on one doesn't affect the other
# ---------------------------------------------------------------------------
send_cmd RPUSH indA aa bb cc > /dev/null
send_cmd RPUSH indB xx yy zz > /dev/null

send_cmd LPOP indA 2 > /dev/null       # removes aa, bb from indA

response=$(send_cmd LRANGE indA 0 -1)
check "indA after LPOP 2 → [cc]" "$response" "$(expect_array cc)"

response=$(send_cmd LRANGE indB 0 -1)
check "indB unaffected → [xx,yy,zz]" "$response" "$(expect_array xx yy zz)"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 12 passed."
else
    exit 1
fi
