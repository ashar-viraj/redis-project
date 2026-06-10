#!/bin/bash
# Stage 15: Verify XADD creates streams and TYPE reports stream keys

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 15: XADD create stream ==="

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

random_digits() {
    local target_len="$1"
    local out=""
    while [ "${#out}" -lt "$target_len" ]; do
        out="${out}${RANDOM}"
    done
    printf '%s' "${out:0:$target_len}"
}

# ---------------------------------------------------------------------------
# Test 1: XADD creates a new stream and returns the explicit ID as a bulk string
# ---------------------------------------------------------------------------
response=$(send_cmd XADD stream_key 0-1 foo bar)
check "XADD new stream, one field → bulk ID 0-1" "$response" "$(expect_bulk 0-1)"

response=$(send_cmd TYPE stream_key)
check "TYPE stream_key after XADD → +stream" "$response" "$(expect_simple stream)"

# ---------------------------------------------------------------------------
# Test 2: TYPE still returns none for missing keys
# ---------------------------------------------------------------------------
response=$(send_cmd TYPE missing_stream_key)
check "TYPE missing stream key → +none" "$response" "$(expect_simple none)"

# ---------------------------------------------------------------------------
# Test 3: TYPE still returns string for keys created by SET
# ---------------------------------------------------------------------------
response=$(send_cmd SET string_key hello)
check "SET string_key hello → +OK" "$response" "$(expect_ok)"

response=$(send_cmd TYPE string_key)
check "TYPE string key after stream creation → +string" "$response" "$(expect_simple string)"

# ---------------------------------------------------------------------------
# Test 4: XADD appends another entry to the same stream and keeps the type stream
# ---------------------------------------------------------------------------
response=$(send_cmd XADD stream_key 0-2 temperature 36 humidity 95)
check "XADD existing stream, multiple fields → bulk ID 0-2" "$response" "$(expect_bulk 0-2)"

response=$(send_cmd TYPE stream_key)
check "TYPE stream_key after append → +stream" "$response" "$(expect_simple stream)"

# ---------------------------------------------------------------------------
# Test 5: A longer Redis-like ID is returned exactly
# ---------------------------------------------------------------------------
LONG_ID=1526919030474-0
response=$(send_cmd XADD sensor_stream "$LONG_ID" temperature 36 humidity 95)
check "XADD with long explicit ID → same bulk ID" "$response" "$(expect_bulk "$LONG_ID")"

response=$(send_cmd TYPE sensor_stream)
check "TYPE sensor_stream → +stream" "$response" "$(expect_simple stream)"

# ---------------------------------------------------------------------------
# Test 6: Multiple independent streams do not affect each other's TYPE
# ---------------------------------------------------------------------------
response=$(send_cmd XADD stream_a 10-0 field_a value_a)
check "XADD stream_a → bulk ID 10-0" "$response" "$(expect_bulk 10-0)"

response=$(send_cmd XADD stream_b 20-0 field_b value_b)
check "XADD stream_b → bulk ID 20-0" "$response" "$(expect_bulk 20-0)"

response=$(send_cmd TYPE stream_a)
check "TYPE stream_a → +stream" "$response" "$(expect_simple stream)"

response=$(send_cmd TYPE stream_b)
check "TYPE stream_b → +stream" "$response" "$(expect_simple stream)"

response=$(send_cmd TYPE stream_c)
check "TYPE untouched stream_c → +none" "$response" "$(expect_simple none)"

# ---------------------------------------------------------------------------
# Test 7: Command names are case-insensitive
# ---------------------------------------------------------------------------
response=$(send_cmd xadd lower_stream 30-0 key value)
check "xadd lowercase command → bulk ID 30-0" "$response" "$(expect_bulk 30-0)"

response=$(send_cmd type lower_stream)
check "type lowercase on stream → +stream" "$response" "$(expect_simple stream)"

response=$(send_cmd XaDd mixed_stream 31-0 key value)
check "XaDd mixed-case command → bulk ID 31-0" "$response" "$(expect_bulk 31-0)"

response=$(send_cmd TyPe mixed_stream)
check "TyPe mixed-case on stream → +stream" "$response" "$(expect_simple stream)"

# ---------------------------------------------------------------------------
# Test 8: Field names and values with spaces are accepted as bulk arguments
# ---------------------------------------------------------------------------
response=$(send_cmd XADD spaced_stream 40-0 "field name" "value with spaces")
check "XADD field/value containing spaces → bulk ID 40-0" "$response" "$(expect_bulk 40-0)"

response=$(send_cmd TYPE spaced_stream)
check "TYPE spaced_stream → +stream" "$response" "$(expect_simple stream)"

# ---------------------------------------------------------------------------
# Test 9: Empty field values are still stream entries
# ---------------------------------------------------------------------------
response=$(send_cmd XADD empty_value_stream 50-0 empty_field "")
check "XADD empty field value → bulk ID 50-0" "$response" "$(expect_bulk 50-0)"

response=$(send_cmd TYPE empty_value_stream)
check "TYPE empty_value_stream → +stream" "$response" "$(expect_simple stream)"

# ---------------------------------------------------------------------------
# Test 10: Numeric-looking field names and values are still normal fields
# ---------------------------------------------------------------------------
response=$(send_cmd XADD numeric_fields_stream 60-0 123 456 789 1000)
check "XADD numeric-looking fields/values → bulk ID 60-0" "$response" "$(expect_bulk 60-0)"

response=$(send_cmd TYPE numeric_fields_stream)
check "TYPE numeric_fields_stream → +stream" "$response" "$(expect_simple stream)"

# ---------------------------------------------------------------------------
# Test 11: Random stream key and explicit ID prevent hardcoded behavior
# ---------------------------------------------------------------------------
RAND_STREAM="stream_$(random_digits 8)"
RAND_ID="$(random_digits 13)-$(random_digits 2)"

response=$(send_cmd XADD "$RAND_STREAM" "$RAND_ID" random_field random_value)
check "XADD random stream/id → same bulk ID" "$response" "$(expect_bulk "$RAND_ID")"

response=$(send_cmd TYPE "$RAND_STREAM")
check "TYPE random stream key → +stream" "$response" "$(expect_simple stream)"

response=$(send_cmd TYPE "${RAND_STREAM}_missing")
check "TYPE similar missing random key → +none" "$response" "$(expect_simple none)"

# ---------------------------------------------------------------------------
# Test 12: Streams and strings keep distinct types side-by-side
# ---------------------------------------------------------------------------
send_cmd SET shared_prefix_string value > /dev/null
send_cmd XADD shared_prefix_stream 70-0 field value > /dev/null

response=$(send_cmd TYPE shared_prefix_string)
check "TYPE shared prefix string key → +string" "$response" "$(expect_simple string)"

response=$(send_cmd TYPE shared_prefix_stream)
check "TYPE shared prefix stream key → +stream" "$response" "$(expect_simple stream)"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 15 passed."
else
    exit 1
fi
