#!/bin/bash
# Stage 18: Verify XADD fully auto-generates stream entry IDs (*)

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 18: XADD fully auto-generated IDs ==="

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

check_true() {
    local label="$1" condition="$2"
    if eval "$condition"; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_bulk_id_response() {
    local label="$1" response="$2" id="$3"
    if is_valid_id_format "$id" && [ "$response" = "$(expect_bulk "$id")" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected : non-empty bulk string with <milliseconds>-<sequence> ID"
        fail "  got      : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# $() strips trailing \n, so responses end with \r
expect_simple()      { printf '+%s\r' "$1"; }
expect_bulk()        { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_equal_error() { printf -- '-ERR The ID specified in XADD is equal or smaller than the target stream top item\r'; }

now_ms() {
    python3 -c 'import time; print(int(time.time()*1000))'
}

bulk_id_from_response() {
    printf '%s' "$1" | tr -d '\r' | sed -n '2p'
}

is_valid_id_format() {
    [[ "$1" =~ ^[0-9]+-[0-9]+$ ]]
}

id_ms() {
    printf '%s' "${1%%-*}"
}

id_seq() {
    printf '%s' "${1#*-}"
}

id_gt() {
    local left="$1" right="$2"
    local left_ms right_ms left_seq right_seq
    is_valid_id_format "$left" || return 1
    is_valid_id_format "$right" || return 1

    left_ms=$(id_ms "$left")
    right_ms=$(id_ms "$right")
    left_seq=$(id_seq "$left")
    right_seq=$(id_seq "$right")

    if [ "$left_ms" -gt "$right_ms" ]; then
        return 0
    fi
    if [ "$left_ms" -eq "$right_ms" ] && [ "$left_seq" -gt "$right_seq" ]; then
        return 0
    fi
    return 1
}

id_in_window() {
    local id="$1" before="$2" after="$3"
    local ms
    is_valid_id_format "$id" || return 1

    ms=$(id_ms "$id")
    [ "$ms" -ge "$before" ] && [ "$ms" -le "$after" ]
}

check_auto_xadd() {
    local label="$1" stream="$2"
    shift 2

    local before response after id
    before=$(now_ms)
    response=$(send_cmd XADD "$stream" "*" "$@")
    after=$(now_ms)
    id=$(bulk_id_from_response "$response")

    check_bulk_id_response "$label returns a valid bulk ID response" "$response" "$id"
    check_true "$label generated ID has milliseconds-sequence format" "is_valid_id_format $id"
    check_true "$label generated millisecond time is within command window" "id_in_window $id $before $after"
    GENERATED_ID="$id"
}


# ---------------------------------------------------------------------------
# Test 1: XADD * creates a stream and returns a current millisecond ID
# ---------------------------------------------------------------------------
check_auto_xadd "XADD auto_stream *" auto_stream foo bar
AUTO_ID_1="$GENERATED_ID"

response=$(send_cmd TYPE auto_stream)
check "TYPE auto_stream after XADD * → +stream" "$response" "$(expect_simple stream)"

# ---------------------------------------------------------------------------
# Test 2: A second XADD * on the same stream returns a strictly greater ID
# ---------------------------------------------------------------------------
check_auto_xadd "Second XADD auto_stream *" auto_stream bar baz
AUTO_ID_2="$GENERATED_ID"

check_true "Second generated ID is strictly greater than first" "id_gt $AUTO_ID_2 $AUTO_ID_1"

# ---------------------------------------------------------------------------
# Test 3: Several generated IDs remain unique and strictly increasing
# ---------------------------------------------------------------------------
PREV_ID="$AUTO_ID_2"
for i in 1 2 3 4 5; do
    check_auto_xadd "Loop XADD auto_stream * #$i" auto_stream field "value_$i"
    NEXT_ID="$GENERATED_ID"
    check_true "Loop generated ID #$i is greater than previous" "id_gt $NEXT_ID $PREV_ID"
    PREV_ID="$NEXT_ID"
done

# ---------------------------------------------------------------------------
# Test 4: Explicit duplicate of a generated ID is rejected
# ---------------------------------------------------------------------------
response=$(send_cmd XADD auto_stream "$PREV_ID" duplicate value)
check "Explicit duplicate of latest generated ID → top-item error" "$response" "$(expect_equal_error)"

# ---------------------------------------------------------------------------
# Test 5: Partial auto ID with the generated millisecond increments sequence
# ---------------------------------------------------------------------------
if is_valid_id_format "$PREV_ID"; then
    PREV_MS=$(id_ms "$PREV_ID")
    PREV_SEQ=$(id_seq "$PREV_ID")
    EXPECTED_PARTIAL_ID="${PREV_MS}-$((PREV_SEQ + 1))"

    response=$(send_cmd XADD auto_stream "$PREV_MS-*" partial value)
    check "XADD same generated millisecond with -* increments sequence" "$response" \
        "$(expect_bulk "$EXPECTED_PARTIAL_ID")"
else
    fail "XADD same generated millisecond with -* increments sequence"
    fail "  skipped because previous generated ID was invalid: $(printf '%s' "$PREV_ID" | cat -A)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---------------------------------------------------------------------------
# Test 6: Independent streams can each receive valid full-auto IDs
# ---------------------------------------------------------------------------
check_auto_xadd "XADD independent_full_a *" independent_full_a field value
INDEPENDENT_A_ID="$GENERATED_ID"

check_auto_xadd "XADD independent_full_b *" independent_full_b field value
INDEPENDENT_B_ID="$GENERATED_ID"

response=$(send_cmd TYPE independent_full_a)
check "TYPE independent_full_a → +stream" "$response" "$(expect_simple stream)"

response=$(send_cmd TYPE independent_full_b)
check "TYPE independent_full_b → +stream" "$response" "$(expect_simple stream)"

check_true "independent_full_a generated ID is valid" "is_valid_id_format $INDEPENDENT_A_ID"
check_true "independent_full_b generated ID is valid" "is_valid_id_format $INDEPENDENT_B_ID"

# ---------------------------------------------------------------------------
# Test 7: Complex field/value arguments do not affect full-auto generation
# ---------------------------------------------------------------------------
check_auto_xadd "XADD complex_full * with spaces and empty value" \
    complex_full "field name" "value with spaces" empty ""
COMPLEX_ID_1="$GENERATED_ID"

check_auto_xadd "Second XADD complex_full * with numeric-looking values" \
    complex_full number 12345 another 67890
COMPLEX_ID_2="$GENERATED_ID"

check_true "complex_full second generated ID is greater than first" "id_gt $COMPLEX_ID_2 $COMPLEX_ID_1"

# ---------------------------------------------------------------------------
# Test 8: TYPE still returns none and string alongside auto-generated streams
# ---------------------------------------------------------------------------
response=$(send_cmd TYPE missing_full_auto_key)
check "TYPE missing key after XADD * tests → +none" "$response" "$(expect_simple none)"

send_cmd SET full_auto_string value > /dev/null
response=$(send_cmd TYPE full_auto_string)
check "TYPE string key after XADD * tests → +string" "$response" "$(expect_simple string)"

# ---------------------------------------------------------------------------
# Test 9: Explicit lower ID after generated ID is rejected
# ---------------------------------------------------------------------------
response=$(send_cmd XADD auto_stream 0-1 lower_explicit value)
check "Explicit low ID after generated IDs → top-item error" "$response" "$(expect_equal_error)"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 18 passed."
else
    exit 1
fi
