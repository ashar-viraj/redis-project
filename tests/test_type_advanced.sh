#!/bin/bash
# Stage 14 extended: Stress-test TYPE for string and missing keys

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 14 Extended: TYPE command advanced cases ==="

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

write_resp_command() {
    printf '*%d\r\n' "$#"
    for word in "$@"; do
        printf '$%d\r\n%s\r\n' "${#word}" "$word"
    done
}

send_cmd() {
    local tmp
    tmp=$(mktemp)
    write_resp_command "$@" > "$tmp"
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
expect_ok()     { printf '+OK\r'; }
expect_simple() { printf '+%s\r' "$1"; }
expect_bulk()   { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_null()   { printf '$-1\r'; }

random_word() {
    local target_len="$1"
    local out=""
    while [ "${#out}" -lt "$target_len" ]; do
        out="${out}${RANDOM}"
    done
    printf '%s' "${out:0:$target_len}"
}

# ---------------------------------------------------------------------------
# Test 1: Missing key before and after nearby keys are created
# ---------------------------------------------------------------------------
response=$(send_cmd TYPE ghost_key)
check "TYPE missing key before any SET → +none" "$response" "$(expect_simple none)"

send_cmd SET ghost_key_neighbor value > /dev/null
response=$(send_cmd TYPE ghost_key)
check "TYPE missing key with similar existing key → +none" "$response" "$(expect_simple none)"

# ---------------------------------------------------------------------------
# Test 2: Plain string key reports string and remains readable
# ---------------------------------------------------------------------------
response=$(send_cmd SET type_plain alpha)
check "SET plain string → +OK" "$response" "$(expect_ok)"

response=$(send_cmd TYPE type_plain)
check "TYPE plain string → +string" "$response" "$(expect_simple string)"

response=$(send_cmd GET type_plain)
check "GET after TYPE still returns original value" "$response" "$(expect_bulk alpha)"

# ---------------------------------------------------------------------------
# Test 3: TYPE does not mutate state when called repeatedly
# ---------------------------------------------------------------------------
response=$(send_cmd TYPE type_plain)
check "TYPE repeated call 1 → +string" "$response" "$(expect_simple string)"

response=$(send_cmd TYPE type_plain)
check "TYPE repeated call 2 → +string" "$response" "$(expect_simple string)"

response=$(send_cmd GET type_plain)
check "GET after repeated TYPE calls → original value" "$response" "$(expect_bulk alpha)"

# ---------------------------------------------------------------------------
# Test 4: Overwriting a string key keeps the type as string and updates value
# ---------------------------------------------------------------------------
send_cmd SET overwrite_type first > /dev/null
send_cmd SET overwrite_type second > /dev/null

response=$(send_cmd TYPE overwrite_type)
check "TYPE overwritten string key → +string" "$response" "$(expect_simple string)"

response=$(send_cmd GET overwrite_type)
check "GET overwritten key → latest value" "$response" "$(expect_bulk second)"

# ---------------------------------------------------------------------------
# Test 5: Empty string, spaces, and numeric-looking values are all strings
# ---------------------------------------------------------------------------
send_cmd SET empty_value "" > /dev/null
response=$(send_cmd TYPE empty_value)
check "TYPE empty string value → +string" "$response" "$(expect_simple string)"

response=$(send_cmd GET empty_value)
check "GET empty string value → empty bulk string" "$response" "$(expect_bulk "")"

send_cmd SET spaced_value "hello world with spaces" > /dev/null
response=$(send_cmd TYPE spaced_value)
check "TYPE value containing spaces → +string" "$response" "$(expect_simple string)"

send_cmd SET numeric_value 123456 > /dev/null
response=$(send_cmd TYPE numeric_value)
check "TYPE numeric-looking value → +string" "$response" "$(expect_simple string)"

# ---------------------------------------------------------------------------
# Test 6: Command name is case-insensitive for existing and missing keys
# ---------------------------------------------------------------------------
response=$(send_cmd type type_plain)
check "type lowercase existing key → +string" "$response" "$(expect_simple string)"

response=$(send_cmd tYpE type_plain)
check "tYpE mixed-case existing key → +string" "$response" "$(expect_simple string)"

response=$(send_cmd type missing_lowercase_check)
check "type lowercase missing key → +none" "$response" "$(expect_simple none)"

response=$(send_cmd tYpE missing_mixed_case_check)
check "tYpE mixed-case missing key → +none" "$response" "$(expect_simple none)"

# ---------------------------------------------------------------------------
# Test 7: Random keys all report string, while untouched random keys report none
# ---------------------------------------------------------------------------
RAND_KEY_A="type_$(random_word 8)"
RAND_KEY_B="type_$(random_word 8)"
RAND_VAL_A="$(random_word 14)"
RAND_VAL_B="$(random_word 14)"

send_cmd SET "$RAND_KEY_A" "$RAND_VAL_A" > /dev/null
send_cmd SET "$RAND_KEY_B" "$RAND_VAL_B" > /dev/null

response=$(send_cmd TYPE "$RAND_KEY_A")
check "TYPE first random string key → +string" "$response" "$(expect_simple string)"

response=$(send_cmd TYPE "$RAND_KEY_B")
check "TYPE second random string key → +string" "$response" "$(expect_simple string)"

response=$(send_cmd TYPE "${RAND_KEY_A}_missing")
check "TYPE random missing key with existing-key prefix → +none" "$response" "$(expect_simple none)"

# ---------------------------------------------------------------------------
# Test 8: Expiring key reports string before expiry and none after expiry
# ---------------------------------------------------------------------------
send_cmd SET px_type_key alive PX 250 > /dev/null

response=$(send_cmd TYPE px_type_key)
check "TYPE PX key before expiry → +string" "$response" "$(expect_simple string)"

sleep 0.35
response=$(send_cmd TYPE px_type_key)
check "TYPE PX key after expiry → +none" "$response" "$(expect_simple none)"

# ---------------------------------------------------------------------------
# Test 9: Overwriting an expiring key with plain SET clears expiry for TYPE
# ---------------------------------------------------------------------------
send_cmd SET ttl_reset_key old PX 200 > /dev/null
send_cmd SET ttl_reset_key persistent > /dev/null

sleep 0.3
response=$(send_cmd TYPE ttl_reset_key)
check "TYPE overwritten expiring key after old TTL → +string" "$response" "$(expect_simple string)"

response=$(send_cmd GET ttl_reset_key)
check "GET overwritten expiring key after old TTL → persistent" "$response" "$(expect_bulk persistent)"

# ---------------------------------------------------------------------------
# Test 10: Recreating an expired key changes TYPE from none back to string
# ---------------------------------------------------------------------------
send_cmd SET recreate_type temporary PX 100 > /dev/null
sleep 0.2
response=$(send_cmd TYPE recreate_type)
check "TYPE expired key before recreation → +none" "$response" "$(expect_simple none)"

send_cmd SET recreate_type recreated > /dev/null
response=$(send_cmd TYPE recreate_type)
check "TYPE recreated key → +string" "$response" "$(expect_simple string)"

# ---------------------------------------------------------------------------
# Test 11: Ordered SET/TYPE/TYPE/GET sequence returns the expected state
# ---------------------------------------------------------------------------
response=$(send_cmd SET ordered_type value)
check "Ordered sequence: SET → +OK" "$response" "$(expect_ok)"

response=$(send_cmd TYPE ordered_type)
check "Ordered sequence: TYPE existing → +string" "$response" "$(expect_simple string)"

response=$(send_cmd TYPE ordered_missing)
check "Ordered sequence: TYPE missing → +none" "$response" "$(expect_simple none)"

response=$(send_cmd GET ordered_type)
check "Ordered sequence: GET still returns value" "$response" "$(expect_bulk value)"

# ---------------------------------------------------------------------------
# Test 12: TYPE remains none for keys fully consumed by list operations
# This checks key disappearance without requiring TYPE to support list yet.
# ---------------------------------------------------------------------------
send_cmd RPUSH consumed_list one two > /dev/null
send_cmd LPOP consumed_list 2 > /dev/null

response=$(send_cmd TYPE consumed_list)
check "TYPE key removed after consuming list → +none" "$response" "$(expect_simple none)"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 14 extended passed."
else
    exit 1
fi
