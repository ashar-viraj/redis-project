#!/bin/bash
# Stage 17: Verify XADD partially auto-generates stream entry IDs (milliseconds-*)

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 17: XADD partial auto-generated IDs ==="

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
expect_bulk()        { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_simple()      { printf '+%s\r' "$1"; }
expect_equal_error() { printf -- '-ERR The ID specified in XADD is equal or smaller than the target stream top item\r'; }

random_digits() {
    local target_len="$1"
    local out=""
    while [ "${#out}" -lt "$target_len" ]; do
        out="${out}${RANDOM}"
    done
    printf '%s' "${out:0:$target_len}"
}

# ---------------------------------------------------------------------------
# Test 1: 0-* on an empty stream starts at 0-1
# ---------------------------------------------------------------------------
response=$(send_cmd XADD zero_auto 0-* foo bar)
check "XADD empty stream with 0-* → 0-1" "$response" "$(expect_bulk 0-1)"

response=$(send_cmd TYPE zero_auto)
check "TYPE zero_auto after 0-* → +stream" "$response" "$(expect_simple stream)"

# ---------------------------------------------------------------------------
# Test 2: Repeated 0-* increments from the previous 0-time sequence
# ---------------------------------------------------------------------------
response=$(send_cmd XADD zero_auto 0-* bar baz)
check "Second XADD zero_auto 0-* → 0-2" "$response" "$(expect_bulk 0-2)"

response=$(send_cmd XADD zero_auto 0-* baz qux)
check "Third XADD zero_auto 0-* → 0-3" "$response" "$(expect_bulk 0-3)"

# ---------------------------------------------------------------------------
# Test 3: Non-zero time-* on an empty stream starts at sequence 0
# ---------------------------------------------------------------------------
response=$(send_cmd XADD time_auto 5-* foo bar)
check "XADD empty stream with 5-* → 5-0" "$response" "$(expect_bulk 5-0)"

response=$(send_cmd TYPE time_auto)
check "TYPE time_auto after 5-* → +stream" "$response" "$(expect_simple stream)"

# ---------------------------------------------------------------------------
# Test 4: Repeated same time-* increments sequence
# ---------------------------------------------------------------------------
response=$(send_cmd XADD time_auto 5-* bar baz)
check "Second XADD time_auto 5-* → 5-1" "$response" "$(expect_bulk 5-1)"

response=$(send_cmd XADD time_auto 5-* baz qux)
check "Third XADD time_auto 5-* → 5-2" "$response" "$(expect_bulk 5-2)"

# ---------------------------------------------------------------------------
# Test 5: Greater time-* starts sequence back at 0
# ---------------------------------------------------------------------------
response=$(send_cmd XADD time_auto 6-* next value)
check "XADD time_auto 6-* after 5-2 → 6-0" "$response" "$(expect_bulk 6-0)"

response=$(send_cmd XADD time_auto 6-* next2 value2)
check "Second XADD time_auto 6-* → 6-1" "$response" "$(expect_bulk 6-1)"

# ---------------------------------------------------------------------------
# Test 6: Lower time-* is rejected after a greater top ID
# ---------------------------------------------------------------------------
response=$(send_cmd XADD time_auto 5-* old_time value)
check "XADD time_auto 5-* after 6-1 → top-item error" "$response" "$(expect_equal_error)"

response=$(send_cmd XADD time_auto 0-* zero_time_too_old value)
check "XADD time_auto 0-* after 6-1 → top-item error" "$response" "$(expect_equal_error)"

# ---------------------------------------------------------------------------
# Test 7: Partial auto generation after explicit IDs with same time
# ---------------------------------------------------------------------------
response=$(send_cmd XADD explicit_then_auto 10-7 first value)
check "XADD explicit_then_auto 10-7 → bulk ID" "$response" "$(expect_bulk 10-7)"

response=$(send_cmd XADD explicit_then_auto 10-* auto value)
check "XADD explicit_then_auto 10-* after 10-7 → 10-8" "$response" "$(expect_bulk 10-8)"

response=$(send_cmd XADD explicit_then_auto 10-* auto2 value2)
check "Next XADD explicit_then_auto 10-* → 10-9" "$response" "$(expect_bulk 10-9)"

# ---------------------------------------------------------------------------
# Test 8: Partial auto generation after explicit ID with greater time starts at 0
# ---------------------------------------------------------------------------
response=$(send_cmd XADD explicit_then_auto 11-* next_time value)
check "XADD explicit_then_auto 11-* after 10-9 → 11-0" "$response" "$(expect_bulk 11-0)"

response=$(send_cmd XADD explicit_then_auto 10-* old_time value)
check "XADD explicit_then_auto 10-* after 11-0 → top-item error" "$response" "$(expect_equal_error)"

# ---------------------------------------------------------------------------
# Test 9: Explicit ID after partial auto must still be greater than generated top
# ---------------------------------------------------------------------------
response=$(send_cmd XADD auto_then_explicit 20-* auto value)
check "XADD auto_then_explicit 20-* → 20-0" "$response" "$(expect_bulk 20-0)"

response=$(send_cmd XADD auto_then_explicit 20-0 equal_explicit value)
check "Explicit 20-0 after generated 20-0 → top-item error" "$response" "$(expect_equal_error)"

response=$(send_cmd XADD auto_then_explicit 20-1 greater_explicit value)
check "Explicit 20-1 after generated 20-0 → bulk ID" "$response" "$(expect_bulk 20-1)"

response=$(send_cmd XADD auto_then_explicit 20-* auto_after_explicit value)
check "20-* after explicit 20-1 → 20-2" "$response" "$(expect_bulk 20-2)"

# ---------------------------------------------------------------------------
# Test 10: Independent streams generate sequences independently
# ---------------------------------------------------------------------------
response=$(send_cmd XADD independent_auto_a 30-* field value)
check "independent_auto_a first 30-* → 30-0" "$response" "$(expect_bulk 30-0)"

response=$(send_cmd XADD independent_auto_b 30-* field value)
check "independent_auto_b first 30-* → 30-0" "$response" "$(expect_bulk 30-0)"

response=$(send_cmd XADD independent_auto_a 30-* field value2)
check "independent_auto_a second 30-* → 30-1" "$response" "$(expect_bulk 30-1)"

response=$(send_cmd XADD independent_auto_b 30-* field value2)
check "independent_auto_b second 30-* → 30-1" "$response" "$(expect_bulk 30-1)"

# ---------------------------------------------------------------------------
# Test 11: Large millisecond time-* values generate and increment correctly
# ---------------------------------------------------------------------------
BIG_MS=1526919030474

response=$(send_cmd XADD big_partial "$BIG_MS-*" temperature 36 humidity 95)
check "XADD big_partial BIG_MS-* → BIG_MS-0" "$response" "$(expect_bulk "$BIG_MS-0")"

response=$(send_cmd XADD big_partial "$BIG_MS-*" temperature 37 humidity 94)
check "Second XADD big_partial BIG_MS-* → BIG_MS-1" "$response" "$(expect_bulk "$BIG_MS-1")"

response=$(send_cmd XADD big_partial 1526919030475-* temperature 38)
check "XADD big_partial next ms-* → 1526919030475-0" "$response" "$(expect_bulk 1526919030475-0)"

# ---------------------------------------------------------------------------
# Test 12: Random time part behaves like tester's randomized timestamp
# ---------------------------------------------------------------------------
RAND_STREAM="partial_$(random_digits 8)"
RAND_MS="$(random_digits 13)"
RAND_ID_A="${RAND_MS}-0"
RAND_ID_B="${RAND_MS}-1"

response=$(send_cmd XADD "$RAND_STREAM" "$RAND_MS-*" random_field random_value)
check "XADD random stream RAND_MS-* → RAND_MS-0" "$response" "$(expect_bulk "$RAND_ID_A")"

response=$(send_cmd XADD "$RAND_STREAM" "$RAND_MS-*" random_field second_value)
check "Second XADD random stream RAND_MS-* → RAND_MS-1" "$response" "$(expect_bulk "$RAND_ID_B")"

response=$(send_cmd TYPE "$RAND_STREAM")
check "TYPE random partial-auto stream → +stream" "$response" "$(expect_simple stream)"

# ---------------------------------------------------------------------------
# Test 13: Field/value complexity does not affect generated IDs
# ---------------------------------------------------------------------------
response=$(send_cmd XADD complex_fields 40-* "field name" "value with spaces" empty "")
check "XADD 40-* with spaces and empty value → 40-0" "$response" "$(expect_bulk 40-0)"

response=$(send_cmd XADD complex_fields 40-* number 12345)
check "Second XADD complex_fields 40-* → 40-1" "$response" "$(expect_bulk 40-1)"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 17 passed."
else
    exit 1
fi
