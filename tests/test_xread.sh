#!/bin/bash
# Stage 22: Verify XREAD queries a single stream using an exclusive start ID

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
XREAD_TEST_LOG="${XREAD_TEST_LOG:-$TESTS_DIR/test_xread_output.log}"
: > "$XREAD_TEST_LOG"
exec > >(tee -a "$XREAD_TEST_LOG") 2>&1

source "$TESTS_DIR/helpers.sh"

echo "=== Stage 22: XREAD single stream queries ==="
info "Writing a copy of this test output to $XREAD_TEST_LOG"

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
    timeout 6 nc -q 1 127.0.0.1 6379 < "$tmp" 2>/dev/null
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

# $() strips trailing \n, so generated expected responses end with \r
expect_bulk()       { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_simple()     { printf '+%s\r' "$1"; }
expect_null_array() { printf '*-1\r'; }

bulk_line() {
    printf '$%d\r\n%s\r\n' "${#1}" "$1"
}

# Each entry argument is one entry spec:
#   "id|field1|value1|field2|value2|..."
expect_xread() {
    local stream="$1"
    shift

    if [ "$#" -eq 0 ]; then
        expect_null_array
        return
    fi

    local spec id kv_count token
    printf '*1\r\n'
    printf '*2\r\n'
    bulk_line "$stream"
    printf '*%d\r\n' "$#"

    for spec in "$@"; do
        # Preserve a trailing empty token so specs like "id|field|" include
        # the empty bulk string in the expected RESP array.
        if [[ "$spec" == *'|' ]]; then
            spec="${spec}__XREAD_EMPTY_SENTINEL__"
        fi

        IFS='|' read -r -a parts <<< "$spec"
        id="${parts[0]}"
        kv_count=$((${#parts[@]} - 1))

        printf '*2\r\n'
        bulk_line "$id"
        printf '*%d\r\n' "$kv_count"
        for token in "${parts[@]:1}"; do
            if [ "$token" = "__XREAD_EMPTY_SENTINEL__" ]; then
                token=""
            fi
            bulk_line "$token"
        done
    done
}

add_range_entries() {
    local stream="$1" ms="$2" start="$3" end="$4" id
    for id in $(seq "$start" "$end"); do
        send_cmd XADD "$stream" "$ms-$id" idx "$id" bucket "$((id / 25))" parity "$((id % 2))" payload "value_$id" > /dev/null
    done
}

expected_range_entries() {
    local ms="$1" start="$2" end="$3" id
    local specs=()
    for id in $(seq "$start" "$end"); do
        specs+=("$ms-$id|idx|$id|bucket|$((id / 25))|parity|$((id % 2))|payload|value_$id")
    done
    expect_xread big_xread_stream "${specs[@]}"
}

# ---------------------------------------------------------------------------
# Test 1: Codecrafters-style single stream read
# ---------------------------------------------------------------------------
response=$(send_cmd XADD stream_key 0-1 temperature 96)
check "XADD stream_key 0-1 -> bulk ID" "$response" "$(expect_bulk 0-1)"

response=$(send_cmd XREAD STREAMS stream_key 0-0)
check "XREAD STREAMS stream_key 0-0 -> entry 0-1" "$response" \
    "$(expect_xread stream_key "0-1|temperature|96")"

# ---------------------------------------------------------------------------
# Test 2: Exclusive boundary behavior
# ---------------------------------------------------------------------------
send_cmd XADD exclusive_stream 0-1 first one > /dev/null
send_cmd XADD exclusive_stream 0-2 second two > /dev/null
send_cmd XADD exclusive_stream 0-3 third three > /dev/null

response=$(send_cmd XREAD STREAMS exclusive_stream 0-0)
check "XREAD exclusive_stream 0-0 -> all entries greater than 0-0" "$response" \
    "$(expect_xread exclusive_stream "0-1|first|one" "0-2|second|two" "0-3|third|three")"

response=$(send_cmd XREAD STREAMS exclusive_stream 0-1)
check "XREAD exclusive_stream 0-1 -> excludes 0-1" "$response" \
    "$(expect_xread exclusive_stream "0-2|second|two" "0-3|third|three")"

response=$(send_cmd XREAD STREAMS exclusive_stream 0-2)
check "XREAD exclusive_stream 0-2 -> only entries after 0-2" "$response" \
    "$(expect_xread exclusive_stream "0-3|third|three")"

response=$(send_cmd XREAD STREAMS exclusive_stream 0-3)
check "XREAD exclusive_stream 0-3 -> null array after stream tail" "$response" \
    "$(expect_null_array)"

# ---------------------------------------------------------------------------
# Test 3: Different milliseconds and IDs without sequence numbers
# ---------------------------------------------------------------------------
send_cmd XADD ms_xread_stream 10-0 a zero > /dev/null
send_cmd XADD ms_xread_stream 10-1 a one > /dev/null
send_cmd XADD ms_xread_stream 11-0 b two > /dev/null
send_cmd XADD ms_xread_stream 11-1 b three > /dev/null
send_cmd XADD ms_xread_stream 12-0 c four > /dev/null

response=$(send_cmd XREAD STREAMS ms_xread_stream 10-0)
check "XREAD ms_xread_stream 10-0 -> starts at next sequence" "$response" \
    "$(expect_xread ms_xread_stream "10-1|a|one" "11-0|b|two" "11-1|b|three" "12-0|c|four")"

response=$(send_cmd XREAD STREAMS ms_xread_stream 10)
check "XREAD ms_xread_stream 10 -> greater than millisecond 10" "$response" \
    "$(expect_xread ms_xread_stream "11-0|b|two" "11-1|b|three" "12-0|c|four")"

response=$(send_cmd XREAD STREAMS ms_xread_stream 11)
check "XREAD ms_xread_stream 11 -> greater than millisecond 11" "$response" \
    "$(expect_xread ms_xread_stream "12-0|c|four")"

response=$(send_cmd XREAD STREAMS ms_xread_stream 12)
check "XREAD ms_xread_stream 12 -> null array after millisecond 12" "$response" \
    "$(expect_null_array)"

# ---------------------------------------------------------------------------
# Test 4: Preserve ordered field-value arrays and complex bulk strings
# ---------------------------------------------------------------------------
send_cmd XADD sensor_xread_stream 50-0 temperature 36 humidity 95 status ok > /dev/null
send_cmd XADD sensor_xread_stream 50-1 humidity 94 temperature 37 status warn > /dev/null
send_cmd XADD sensor_xread_stream 51-0 "field name" "value with spaces" empty "" > /dev/null
send_cmd XADD sensor_xread_stream 51-1 123 456 "punctuation" "a:b,c.d" > /dev/null

response=$(send_cmd XREAD STREAMS sensor_xread_stream 50-0)
check "XREAD preserves field order, spaces, empty values, and numeric-looking fields" "$response" \
    "$(expect_xread sensor_xread_stream \
        "50-1|humidity|94|temperature|37|status|warn" \
        "51-0|field name|value with spaces|empty|" \
        "51-1|123|456|punctuation|a:b,c.d")"

# ---------------------------------------------------------------------------
# Test 5: Missing streams, wrong key types, and independent streams
# ---------------------------------------------------------------------------
response=$(send_cmd XREAD STREAMS missing_xread_stream 0-0)
check "XREAD missing stream -> null array" "$response" "$(expect_null_array)"

send_cmd SET string_xread_key hello > /dev/null
response=$(send_cmd TYPE string_xread_key)
check "TYPE string_xread_key -> +string" "$response" "$(expect_simple string)"

response=$(send_cmd XREAD STREAMS string_xread_key 0-0)
check "XREAD string key -> null array" "$response" "$(expect_null_array)"

send_cmd XADD alpha_xread_stream 1-0 stream alpha > /dev/null
send_cmd XADD alpha_xread_stream 1-1 stream alpha_next > /dev/null
send_cmd XADD beta_xread_stream 1-0 stream beta > /dev/null
send_cmd XADD beta_xread_stream 1-1 stream beta_next > /dev/null

response=$(send_cmd XREAD STREAMS alpha_xread_stream 1-0)
check "XREAD alpha_xread_stream 1-0 -> only alpha tail" "$response" \
    "$(expect_xread alpha_xread_stream "1-1|stream|alpha_next")"

response=$(send_cmd XREAD STREAMS beta_xread_stream 0-0)
check "XREAD beta_xread_stream 0-0 -> only beta entries" "$response" \
    "$(expect_xread beta_xread_stream "1-0|stream|beta" "1-1|stream|beta_next")"

# ---------------------------------------------------------------------------
# Test 6: Large stream with many entries and multiple exclusive read positions
# ---------------------------------------------------------------------------
add_range_entries big_xread_stream 500 0 149

response=$(send_cmd TYPE big_xread_stream)
check "TYPE big_xread_stream -> +stream" "$response" "$(expect_simple stream)"

response=$(send_cmd XREAD STREAMS big_xread_stream 499-999)
check "XREAD big_xread_stream 499-999 -> all 150 entries" "$response" \
    "$(expected_range_entries 500 0 149)"

response=$(send_cmd XREAD STREAMS big_xread_stream 500-0)
check "XREAD big_xread_stream 500-0 -> entries 1..149" "$response" \
    "$(expected_range_entries 500 1 149)"

response=$(send_cmd XREAD STREAMS big_xread_stream 500-74)
check "XREAD big_xread_stream 500-74 -> final 75 entries" "$response" \
    "$(expected_range_entries 500 75 149)"

response=$(send_cmd XREAD STREAMS big_xread_stream 500-139)
check "XREAD big_xread_stream 500-139 -> final 10 entries" "$response" \
    "$(expected_range_entries 500 140 149)"

response=$(send_cmd XREAD STREAMS big_xread_stream 500-148)
check "XREAD big_xread_stream 500-148 -> last entry only" "$response" \
    "$(expected_range_entries 500 149 149)"

response=$(send_cmd XREAD STREAMS big_xread_stream 500-149)
check "XREAD big_xread_stream 500-149 -> null array after large stream tail" "$response" \
    "$(expect_null_array)"

# ---------------------------------------------------------------------------
# Test 7: Partial-auto and full-auto IDs are readable by returned IDs
# ---------------------------------------------------------------------------
send_cmd XADD auto_xread_stream 600-0 explicit zero > /dev/null
response=$(send_cmd XADD auto_xread_stream 600-* partial auto)
check "XADD auto_xread_stream 600-* -> 600-1" "$response" "$(expect_bulk 600-1)"

auto_response=$(send_cmd XADD auto_xread_stream "*" full auto)
auto_id=$(printf '%s' "$auto_response" | tr -d '\r' | sed -n '2p')

if [[ "$auto_id" =~ ^[0-9]+-[0-9]+$ ]]; then
    response=$(send_cmd XREAD STREAMS auto_xread_stream 600-0)
    check "XREAD auto_xread_stream 600-0 -> partial-auto and full-auto entries" "$response" \
        "$(expect_xread auto_xread_stream "600-1|partial|auto" "$auto_id|full|auto")"

    response=$(send_cmd XREAD STREAMS auto_xread_stream 600-1)
    check "XREAD auto_xread_stream 600-1 -> full-auto entry only" "$response" \
        "$(expect_xread auto_xread_stream "$auto_id|full|auto")"

    response=$(send_cmd XREAD STREAMS auto_xread_stream "$auto_id")
    check "XREAD auto_xread_stream full-auto-id -> null array at tail" "$response" \
        "$(expect_null_array)"
else
    fail "XREAD auto_xread_stream tests"
    fail "  skipped because XADD * did not return a valid ID: $(printf '%s' "$auto_response" | cat -A)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---------------------------------------------------------------------------
# Test 8: Case-insensitive command and STREAMS keyword
# ---------------------------------------------------------------------------
response=$(send_cmd xread streams exclusive_stream 0-2)
check "xread lowercase command and streams keyword -> entry after 0-2" "$response" \
    "$(expect_xread exclusive_stream "0-3|third|three")"

response=$(send_cmd XrEaD StReAmS exclusive_stream 0-1)
check "XrEaD mixed-case command and STREAMS keyword -> entries after 0-1" "$response" \
    "$(expect_xread exclusive_stream "0-2|second|two" "0-3|third|three")"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 22 passed."
else
    exit 1
fi
