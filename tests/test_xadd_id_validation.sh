#!/bin/bash
# Stage 16: Verify XADD validates explicit stream entry IDs

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 16: XADD entry ID validation ==="

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
expect_zero_error()  { printf -- '-ERR The ID specified in XADD must be greater than 0-0\r'; }

random_digits() {
    local target_len="$1"
    local out=""
    while [ "${#out}" -lt "$target_len" ]; do
        out="${out}${RANDOM}"
    done
    printf '%s' "${out:0:$target_len}"
}

# ---------------------------------------------------------------------------
# Test 1: Minimum valid ID on an empty stream is 0-1
# ---------------------------------------------------------------------------
response=$(send_cmd XADD min_stream 0-1 foo bar)
check "XADD empty stream with minimum valid ID 0-1 → bulk ID" "$response" "$(expect_bulk 0-1)"

response=$(send_cmd TYPE min_stream)
check "TYPE min_stream after valid 0-1 → +stream" "$response" "$(expect_simple stream)"

# ---------------------------------------------------------------------------
# Test 2: 0-0 is invalid on an empty stream
# ---------------------------------------------------------------------------
response=$(send_cmd XADD zero_empty 0-0 foo bar)
check "XADD empty stream with 0-0 → greater-than-0-0 error" "$response" "$(expect_zero_error)"

response=$(send_cmd TYPE zero_empty)
check "TYPE zero_empty after rejected XADD → +none" "$response" "$(expect_simple none)"

# ---------------------------------------------------------------------------
# Test 3: Same millisecond time with increasing sequence is valid
# ---------------------------------------------------------------------------
response=$(send_cmd XADD ordered_stream 1-1 foo bar)
check "XADD ordered_stream 1-1 → bulk ID" "$response" "$(expect_bulk 1-1)"

response=$(send_cmd XADD ordered_stream 1-2 bar baz)
check "XADD ordered_stream 1-2 → bulk ID" "$response" "$(expect_bulk 1-2)"

response=$(send_cmd XADD ordered_stream 1-3 baz qux)
check "XADD ordered_stream 1-3 → bulk ID" "$response" "$(expect_bulk 1-3)"

# ---------------------------------------------------------------------------
# Test 4: Equal ID is rejected
# ---------------------------------------------------------------------------
response=$(send_cmd XADD ordered_stream 1-3 duplicate value)
check "XADD equal to top ID 1-3 → top-item error" "$response" "$(expect_equal_error)"

# ---------------------------------------------------------------------------
# Test 5: Same time with lower sequence is rejected
# ---------------------------------------------------------------------------
response=$(send_cmd XADD ordered_stream 1-2 lower_sequence value)
check "XADD same time but lower sequence 1-2 → top-item error" "$response" "$(expect_equal_error)"

response=$(send_cmd XADD ordered_stream 1-0 much_lower_sequence value)
check "XADD same time but much lower sequence 1-0 → top-item error" "$response" "$(expect_equal_error)"

# ---------------------------------------------------------------------------
# Test 6: Lower time is rejected even if sequence is larger
# ---------------------------------------------------------------------------
response=$(send_cmd XADD ordered_stream 0-999 lower_time_large_sequence value)
check "XADD lower time 0-999 after 1-3 → top-item error" "$response" "$(expect_equal_error)"

# ---------------------------------------------------------------------------
# Test 7: Greater time is valid even with sequence 0
# ---------------------------------------------------------------------------
response=$(send_cmd XADD ordered_stream 2-0 greater_time_zero_sequence value)
check "XADD greater time 2-0 after 1-3 → bulk ID" "$response" "$(expect_bulk 2-0)"

response=$(send_cmd XADD ordered_stream 2-1 greater_time_next_sequence value)
check "XADD same greater time 2-1 → bulk ID" "$response" "$(expect_bulk 2-1)"

# ---------------------------------------------------------------------------
# Test 8: 0-0 is always rejected, even after stream already exists
# ---------------------------------------------------------------------------
response=$(send_cmd XADD ordered_stream 0-0 zero_again value)
check "XADD existing stream with 0-0 → greater-than-0-0 error" "$response" "$(expect_zero_error)"

# ---------------------------------------------------------------------------
# Test 9: Rejected IDs do not advance the stream top item
# ---------------------------------------------------------------------------
response=$(send_cmd XADD no_advance_stream 5-0 first value)
check "XADD no_advance_stream 5-0 → bulk ID" "$response" "$(expect_bulk 5-0)"

response=$(send_cmd XADD no_advance_stream 5-0 rejected_same value)
check "Rejected equal ID on no_advance_stream → top-item error" "$response" "$(expect_equal_error)"

response=$(send_cmd XADD no_advance_stream 4-999 rejected_lower_time value)
check "Rejected lower time on no_advance_stream → top-item error" "$response" "$(expect_equal_error)"

response=$(send_cmd XADD no_advance_stream 5-1 next_valid value)
check "Valid 5-1 after rejected IDs → bulk ID" "$response" "$(expect_bulk 5-1)"

# ---------------------------------------------------------------------------
# Test 10: Each stream tracks its own top ID independently
# ---------------------------------------------------------------------------
response=$(send_cmd XADD independent_a 100-0 field value)
check "XADD independent_a 100-0 → bulk ID" "$response" "$(expect_bulk 100-0)"

response=$(send_cmd XADD independent_b 1-0 field value)
check "XADD independent_b can start lower than independent_a → bulk ID" "$response" "$(expect_bulk 1-0)"

response=$(send_cmd XADD independent_a 99-999 lower_for_a value)
check "XADD independent_a 99-999 → top-item error" "$response" "$(expect_equal_error)"

response=$(send_cmd XADD independent_b 1-1 next_for_b value)
check "XADD independent_b 1-1 still valid → bulk ID" "$response" "$(expect_bulk 1-1)"

# ---------------------------------------------------------------------------
# Test 11: Large IDs compare numerically, not lexicographically
# ---------------------------------------------------------------------------
response=$(send_cmd XADD numeric_compare 9-999 near_ten value)
check "XADD numeric_compare 9-999 → bulk ID" "$response" "$(expect_bulk 9-999)"

response=$(send_cmd XADD numeric_compare 10-0 ten_zero value)
check "XADD numeric_compare 10-0 after 9-999 → bulk ID" "$response" "$(expect_bulk 10-0)"

response=$(send_cmd XADD numeric_compare 9-1000 lexicographic_trap value)
check "XADD numeric_compare 9-1000 after 10-0 → top-item error" "$response" "$(expect_equal_error)"

# ---------------------------------------------------------------------------
# Test 12: Very large millisecond and sequence values are accepted in order
# ---------------------------------------------------------------------------
BIG_ID_A=1526919030474-0
BIG_ID_B=1526919030474-1
BIG_ID_C=1526919030475-0

response=$(send_cmd XADD big_id_stream "$BIG_ID_A" temperature 36)
check "XADD big_id_stream first large ID → bulk ID" "$response" "$(expect_bulk "$BIG_ID_A")"

response=$(send_cmd XADD big_id_stream "$BIG_ID_B" humidity 95)
check "XADD big_id_stream same ms higher seq → bulk ID" "$response" "$(expect_bulk "$BIG_ID_B")"

response=$(send_cmd XADD big_id_stream "$BIG_ID_C" pressure 1000)
check "XADD big_id_stream higher ms seq 0 → bulk ID" "$response" "$(expect_bulk "$BIG_ID_C")"

response=$(send_cmd XADD big_id_stream "$BIG_ID_B" old_again value)
check "XADD big_id_stream old large ID → top-item error" "$response" "$(expect_equal_error)"

# ---------------------------------------------------------------------------
# Test 13: Random stream uses generated increasing explicit IDs
# ---------------------------------------------------------------------------
RAND_STREAM="valid_ids_$(random_digits 8)"
RAND_MS="$(random_digits 13)"
RAND_ID_A="${RAND_MS}-0"
RAND_ID_B="${RAND_MS}-1"

response=$(send_cmd XADD "$RAND_STREAM" "$RAND_ID_A" field value)
check "XADD random stream first generated ID → bulk ID" "$response" "$(expect_bulk "$RAND_ID_A")"

response=$(send_cmd XADD "$RAND_STREAM" "$RAND_ID_B" field value)
check "XADD random stream next generated ID → bulk ID" "$response" "$(expect_bulk "$RAND_ID_B")"

response=$(send_cmd XADD "$RAND_STREAM" "$RAND_ID_A" old_random value)
check "XADD random stream old generated ID → top-item error" "$response" "$(expect_equal_error)"

response=$(send_cmd TYPE "$RAND_STREAM")
check "TYPE random validation stream → +stream" "$response" "$(expect_simple stream)"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 16 passed."
else
    exit 1
fi
