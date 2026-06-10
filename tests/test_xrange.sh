#!/bin/bash
# Stage 19: Verify XRANGE queries stream entries across inclusive ID ranges

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
XRANGE_TEST_LOG="${XRANGE_TEST_LOG:-$TESTS_DIR/test_xrange_output.log}"
: > "$XRANGE_TEST_LOG"
exec > >(tee -a "$XRANGE_TEST_LOG") 2>&1

source "$TESTS_DIR/helpers.sh"

echo "=== Stage 19: XRANGE stream queries ==="
info "Writing a copy of this test output to $XRANGE_TEST_LOG"

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

# $() strips trailing \n, so generated expected responses end with \r
expect_bulk()        { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_simple()      { printf '+%s\r' "$1"; }
expect_empty_array() { printf '*0\r'; }

bulk_line() {
    printf '$%d\r\n%s\r\n' "${#1}" "$1"
}

# Each argument is one entry spec:
#   "id|field1|value1|field2|value2|..."
expect_xrange() {
    if [ "$#" -eq 0 ]; then
        expect_empty_array
        return
    fi

    local spec id kv_count token
    printf '*%d\r\n' "$#"
    for spec in "$@"; do
        # Preserve a trailing empty token so specs like "id|field|" include
        # the empty bulk string in the expected RESP array.
        if [[ "$spec" == *'|' ]]; then
            spec="${spec}__XRANGE_EMPTY_SENTINEL__"
        fi

        IFS='|' read -r -a parts <<< "$spec"
        id="${parts[0]}"
        kv_count=$((${#parts[@]} - 1))

        printf '*2\r\n'
        bulk_line "$id"
        printf '*%d\r\n' "$kv_count"
        for token in "${parts[@]:1}"; do
            if [ "$token" = "__XRANGE_EMPTY_SENTINEL__" ]; then
                token=""
            fi
            bulk_line "$token"
        done
    done
}

add_many_entries() {
    local stream="$1" start="$2" end="$3" id
    for id in $(seq "$start" "$end"); do
        send_cmd XADD "$stream" "100-$id" idx "$id" parity "$((id % 2))" payload "value_$id" > /dev/null
    done
}

expected_many_entries() {
    local start="$1" end="$2" id
    local specs=()
    for id in $(seq "$start" "$end"); do
        specs+=("100-$id|idx|$id|parity|$((id % 2))|payload|value_$id")
    done
    expect_xrange "${specs[@]}"
}


# ---------------------------------------------------------------------------
# Test 1: Basic tester-style setup and inclusive range
# ---------------------------------------------------------------------------
response=$(send_cmd XADD stream_key 0-1 foo bar)
check "XADD stream_key 0-1 -> bulk ID" "$response" "$(expect_bulk 0-1)"

response=$(send_cmd XADD stream_key 0-2 bar baz)
check "XADD stream_key 0-2 -> bulk ID" "$response" "$(expect_bulk 0-2)"

response=$(send_cmd XADD stream_key 0-3 baz foo)
check "XADD stream_key 0-3 -> bulk ID" "$response" "$(expect_bulk 0-3)"

response=$(send_cmd XRANGE stream_key 0-2 0-3)
check "XRANGE stream_key 0-2 0-3 -> entries 0-2 and 0-3" "$response" \
    "$(expect_xrange "0-2|bar|baz" "0-3|baz|foo")"

# ---------------------------------------------------------------------------
# Test 2: Full range and single-entry exact range
# ---------------------------------------------------------------------------
response=$(send_cmd XRANGE stream_key 0-1 0-3)
check "XRANGE full explicit range includes all entries" "$response" \
    "$(expect_xrange "0-1|foo|bar" "0-2|bar|baz" "0-3|baz|foo")"

response=$(send_cmd XRANGE stream_key 0-2 0-2)
check "XRANGE exact same start/end returns one entry" "$response" \
    "$(expect_xrange "0-2|bar|baz")"

# ---------------------------------------------------------------------------
# Test 3: Empty ranges
# ---------------------------------------------------------------------------
response=$(send_cmd XRANGE stream_key 0-4 0-9)
check "XRANGE after last entry -> empty array" "$response" "$(expect_empty_array)"

response=$(send_cmd XRANGE stream_key 0-3 0-2)
check "XRANGE start greater than end -> empty array" "$response" "$(expect_empty_array)"

response=$(send_cmd XRANGE missing_stream 0-1 0-9)
check "XRANGE missing stream -> empty array" "$response" "$(expect_empty_array)"

# ---------------------------------------------------------------------------
# Test 4: Optional sequence number boundaries
# Start ID without sequence defaults to sequence 0.
# End ID without sequence includes the maximum sequence for that millisecond.
# ---------------------------------------------------------------------------
send_cmd XADD ms_stream 10-0 a first > /dev/null
send_cmd XADD ms_stream 10-1 b second > /dev/null
send_cmd XADD ms_stream 10-2 c third > /dev/null
send_cmd XADD ms_stream 11-0 d fourth > /dev/null
send_cmd XADD ms_stream 11-1 e fifth > /dev/null

response=$(send_cmd XRANGE ms_stream 10 10)
check "XRANGE ms_stream 10 10 -> all entries at millisecond 10" "$response" \
    "$(expect_xrange "10-0|a|first" "10-1|b|second" "10-2|c|third")"

response=$(send_cmd XRANGE ms_stream 10-1 11)
check "XRANGE ms_stream 10-1 11 -> starts at seq 1, end includes all seq at 11" "$response" \
    "$(expect_xrange "10-1|b|second" "10-2|c|third" "11-0|d|fourth" "11-1|e|fifth")"

response=$(send_cmd XRANGE ms_stream 11 11)
check "XRANGE ms_stream 11 11 -> all entries at millisecond 11" "$response" \
    "$(expect_xrange "11-0|d|fourth" "11-1|e|fifth")"

# ---------------------------------------------------------------------------
# Test 5: Entries preserve field-value order and support multiple pairs
# ---------------------------------------------------------------------------
send_cmd XADD sensor_stream 50-0 temperature 36 humidity 95 status ok > /dev/null
send_cmd XADD sensor_stream 50-1 humidity 94 temperature 37 status warn > /dev/null
send_cmd XADD sensor_stream 51-0 "field name" "value with spaces" empty "" > /dev/null

response=$(send_cmd XRANGE sensor_stream 50-0 51-0)
check "XRANGE preserves field order and complex values" "$response" \
    "$(expect_xrange \
        "50-0|temperature|36|humidity|95|status|ok" \
        "50-1|humidity|94|temperature|37|status|warn" \
        "51-0|field name|value with spaces|empty|")"

# ---------------------------------------------------------------------------
# Test 6: Large stream with many entries and multiple sliced ranges
# ---------------------------------------------------------------------------
add_many_entries big_stream 0 49

response=$(send_cmd TYPE big_stream)
check "TYPE big_stream -> +stream" "$response" "$(expect_simple stream)"

response=$(send_cmd XRANGE big_stream 100-0 100-49)
check "XRANGE big_stream full 50-entry range" "$response" "$(expected_many_entries 0 49)"

response=$(send_cmd XRANGE big_stream 100-10 100-19)
check "XRANGE big_stream middle slice 10..19" "$response" "$(expected_many_entries 10 19)"

response=$(send_cmd XRANGE big_stream 100-0 100-0)
check "XRANGE big_stream first entry only" "$response" "$(expected_many_entries 0 0)"

response=$(send_cmd XRANGE big_stream 100-49 100-49)
check "XRANGE big_stream last entry only" "$response" "$(expected_many_entries 49 49)"

response=$(send_cmd XRANGE big_stream 100-45 101)
check "XRANGE big_stream tail using end without sequence past last ms" "$response" \
    "$(expected_many_entries 45 49)"

response=$(send_cmd XRANGE big_stream 99 100-2)
check "XRANGE big_stream start before first includes first three" "$response" \
    "$(expected_many_entries 0 2)"

# ---------------------------------------------------------------------------
# Test 7: Mixed explicit, partial-auto, and full-auto IDs can be queried
# ---------------------------------------------------------------------------
send_cmd XADD mixed_id_stream 200-0 explicit zero > /dev/null
response=$(send_cmd XADD mixed_id_stream 200-* partial auto)
check "XADD mixed_id_stream 200-* -> 200-1" "$response" "$(expect_bulk 200-1)"

auto_response=$(send_cmd XADD mixed_id_stream "*" full auto)
auto_id=$(printf '%s' "$auto_response" | tr -d '\r' | sed -n '2p')

response=$(send_cmd XRANGE mixed_id_stream 200 200)
check "XRANGE mixed_id_stream 200 200 -> explicit and partial-auto entries" "$response" \
    "$(expect_xrange "200-0|explicit|zero" "200-1|partial|auto")"

if [[ "$auto_id" =~ ^[0-9]+-[0-9]+$ ]]; then
    response=$(send_cmd XRANGE mixed_id_stream "$auto_id" "$auto_id")
    check "XRANGE mixed_id_stream exact full-auto ID" "$response" \
        "$(expect_xrange "$auto_id|full|auto")"
else
    fail "XRANGE mixed_id_stream exact full-auto ID"
    fail "  skipped because XADD * did not return a valid ID: $(printf '%s' "$auto_response" | cat -A)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---------------------------------------------------------------------------
# Test 8: Case-insensitive command name
# ---------------------------------------------------------------------------
response=$(send_cmd xrange stream_key 0-1 0-1)
check "xrange lowercase command -> first entry" "$response" "$(expect_xrange "0-1|foo|bar")"

response=$(send_cmd XrAnGe stream_key 0-3 0-3)
check "XrAnGe mixed-case command -> last entry" "$response" "$(expect_xrange "0-3|baz|foo")"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 19 passed."
else
    exit 1
fi
