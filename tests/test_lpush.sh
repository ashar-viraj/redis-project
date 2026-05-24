#!/bin/bash
# Stage 11: Verify the LPUSH command (prepend elements, verify ordering with LRANGE)

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 11: LPUSH command ==="

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Helpers — same pattern across all test scripts (temp file avoids $() \r\n stripping)
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

# $() strips trailing \n, so responses end with \r
expect_int()         { printf ':%d\r' "$1"; }
expect_empty_array() { printf '*0\r'; }
expect_array() {
    [ $# -eq 0 ] && { expect_empty_array; return; }
    local count=$# i=1
    printf '*%d\r\n' "$count"
    for word in "$@"; do
        if [ "$i" -eq "$count" ]; then
            printf '$%d\r\n%s\r' "${#word}" "$word"   # last: no trailing \n
        else
            printf '$%d\r\n%s\r\n' "${#word}" "$word"
        fi
        i=$((i + 1))
    done
}

# ---------------------------------------------------------------------------
# Test 1: LPUSH single element to a new list → :1, list is [c]
# ---------------------------------------------------------------------------
response=$(send_cmd LPUSH mylist c)
check "LPUSH new list 'c' → :1" "$response" "$(expect_int 1)"

response=$(send_cmd LRANGE mylist 0 -1)
check "LRANGE after LPUSH 'c' → [c]" "$response" "$(expect_array c)"

# ---------------------------------------------------------------------------
# Test 2: LPUSH single element to existing list — prepended, count grows
# LPUSH mylist b  →  list becomes [b, c], returns :2
# ---------------------------------------------------------------------------
response=$(send_cmd LPUSH mylist b)
check "LPUSH 'b' to [c] → :2" "$response" "$(expect_int 2)"

response=$(send_cmd LRANGE mylist 0 -1)
check "LRANGE after LPUSH 'b' → [b,c]" "$response" "$(expect_array b c)"

# ---------------------------------------------------------------------------
# Test 3: LPUSH multiple elements in one call
# LPUSH mylist a b  →  each prepended left-to-right in args, so:
#   prepend a → [a, b, c]
#   prepend b → [b, a, b, c]  ← wait, that's wrong for this test
#
# Use a fresh key. LPUSH fresh_key a b c:
#   prepend a → [a]
#   prepend b → [b, a]
#   prepend c → [c, b, a]
# Result: [c, b, a], returns :3
# ---------------------------------------------------------------------------
response=$(send_cmd LPUSH multikey a b c)
check "LPUSH 3 elements at once to new list → :3" "$response" "$(expect_int 3)"

response=$(send_cmd LRANGE multikey 0 -1)
check "LRANGE after LPUSH a b c → [c,b,a]" "$response" "$(expect_array c b a)"

# ---------------------------------------------------------------------------
# Test 4: Continued multi-element LPUSH
# LPUSH multikey x y  →  prepend x → [x,c,b,a], prepend y → [y,x,c,b,a], returns :5
# ---------------------------------------------------------------------------
response=$(send_cmd LPUSH multikey x y)
check "LPUSH 'x y' to [c,b,a] → :5" "$response" "$(expect_int 5)"

response=$(send_cmd LRANGE multikey 0 -1)
check "LRANGE after LPUSH x y → [y,x,c,b,a]" "$response" "$(expect_array y x c b a)"

# ---------------------------------------------------------------------------
# Test 5: Mix RPUSH + LPUSH — verify absolute positions
#
# Start fresh list 'mixed':
#   RPUSH mixed p q r  →  [p, q, r]
#   LPUSH mixed z      →  [z, p, q, r]
#   LPUSH mixed a b    →  prepend a → [a,z,p,q,r], prepend b → [b,a,z,p,q,r]
#   RPUSH mixed s      →  [b, a, z, p, q, r, s]
# ---------------------------------------------------------------------------
send_cmd RPUSH mixed p q r > /dev/null        # [p, q, r]
response=$(send_cmd LPUSH mixed z)
check "LPUSH 'z' after RPUSH p q r → :4" "$response" "$(expect_int 4)"

response=$(send_cmd LRANGE mixed 0 -1)
check "LRANGE → [z,p,q,r]" "$response" "$(expect_array z p q r)"

response=$(send_cmd LPUSH mixed a b)          # prepend a then b → [b,a,z,p,q,r]
check "LPUSH 'a b' → :6" "$response" "$(expect_int 6)"

send_cmd RPUSH mixed s > /dev/null            # [b,a,z,p,q,r,s]
response=$(send_cmd LRANGE mixed 0 -1)
check "LRANGE after mixed RPUSH/LPUSH → [b,a,z,p,q,r,s]" "$response" \
    "$(expect_array b a z p q r s)"

# Spot-check with negative indexes
response=$(send_cmd LRANGE mixed -3 -1)
check "LRANGE mixed -3 -1 → [q,r,s]" "$response" "$(expect_array q r s)"

response=$(send_cmd LRANGE mixed 0 2)
check "LRANGE mixed 0 2 → [b,a,z]" "$response" "$(expect_array b a z)"

# ---------------------------------------------------------------------------
# Test 6: Random key/value (ensures nothing is hardcoded)
# ---------------------------------------------------------------------------
RAND_KEY=$(cat /dev/urandom | tr -dc 'a-z' | head -c 8)
RAND_V1=$(cat /dev/urandom | tr -dc 'a-z' | head -c 5)
RAND_V2=$(cat /dev/urandom | tr -dc 'a-z' | head -c 5)
RAND_V3=$(cat /dev/urandom | tr -dc 'a-z' | head -c 5)

response=$(send_cmd LPUSH "$RAND_KEY" "$RAND_V1")
check "LPUSH random v1 → :1" "$response" "$(expect_int 1)"

response=$(send_cmd LPUSH "$RAND_KEY" "$RAND_V2" "$RAND_V3")
check "LPUSH random v2 v3 → :3" "$response" "$(expect_int 3)"

# LPUSH v2 v3: prepend v2 → [v2,v1], prepend v3 → [v3,v2,v1]
response=$(send_cmd LRANGE "$RAND_KEY" 0 -1)
check "LRANGE random list → [v3,v2,v1]" "$response" \
    "$(expect_array "$RAND_V3" "$RAND_V2" "$RAND_V1")"

# ---------------------------------------------------------------------------
# Test 7: Case-insensitive command — lowercase lpush
# ---------------------------------------------------------------------------
response=$(send_cmd lpush lc_list alpha)
check "lpush (lowercase) → :1" "$response" "$(expect_int 1)"

response=$(send_cmd lrange lc_list 0 -1)
check "lrange (lowercase) → [alpha]" "$response" "$(expect_array alpha)"

# ---------------------------------------------------------------------------
# Test 8: Case-insensitive — mixed case lPuSh
# ---------------------------------------------------------------------------
response=$(send_cmd lPuSh mc_list gamma beta)
check "lPuSh (mixed case) 'gamma beta' → :2" "$response" "$(expect_int 2)"

response=$(send_cmd LRANGE mc_list 0 -1)
check "LRANGE after lPuSh gamma beta → [beta,gamma]" "$response" "$(expect_array beta gamma)"

# ---------------------------------------------------------------------------
# Test 9: Two independent lists don't share state
# ---------------------------------------------------------------------------
send_cmd LPUSH indA one two three > /dev/null   # [three, two, one]
send_cmd LPUSH indB x > /dev/null               # [x]

response=$(send_cmd LPUSH indB y)
check "LPUSH indB 'y': independent count → :2" "$response" "$(expect_int 2)"

response=$(send_cmd LRANGE indA 0 -1)
check "indA unaffected by indB operations → [three,two,one]" "$response" \
    "$(expect_array three two one)"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 11 passed."
else
    exit 1
fi
