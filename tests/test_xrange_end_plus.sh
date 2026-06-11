#!/bin/bash
# Stage 21: Verify XRANGE supports '+' as the end ID

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
XRANGE_PLUS_TEST_LOG="${XRANGE_PLUS_TEST_LOG:-$TESTS_DIR/test_xrange_end_plus_output.log}"
: > "$XRANGE_PLUS_TEST_LOG"
exec > >(tee -a "$XRANGE_PLUS_TEST_LOG") 2>&1

source "$TESTS_DIR/helpers.sh"

echo "=== Stage 21: XRANGE with '+' end ID ==="
info "Writing a copy of this test output to $XRANGE_PLUS_TEST_LOG"

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
    timeout 5 nc -q 1 127.0.0.1 6379 < "$tmp" 2>/dev/null
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

add_range_entries() {
    local stream="$1" ms="$2" start="$3" end="$4" id
    for id in $(seq "$start" "$end"); do
        send_cmd XADD "$stream" "$ms-$id" idx "$id" group "$((id / 10))" payload "value_$id" > /dev/null
    done
}

expected_range_entries() {
    local ms="$1" start="$2" end="$3" id
    local specs=()
    for id in $(seq "$start" "$end"); do
        specs+=("$ms-$id|idx|$id|group|$((id / 10))|payload|value_$id")
    done
    expect_xrange "${specs[@]}"
}

# ---------------------------------------------------------------------------
# Test 1: Codecrafters-style example, '+' returns through the stream tail
# ---------------------------------------------------------------------------
response=$(send_cmd XADD plus_stream 0-1 foo bar)
check "XADD plus_stream 0-1 -> bulk ID" "$response" "$(expect_bulk 0-1)"

response=$(send_cmd XADD plus_stream 0-2 bar baz)
check "XADD plus_stream 0-2 -> bulk ID" "$response" "$(expect_bulk 0-2)"

response=$(send_cmd XADD plus_stream 0-3 baz foo)
check "XADD plus_stream 0-3 -> bulk ID" "$response" "$(expect_bulk 0-3)"

response=$(send_cmd XRANGE plus_stream 0-2 +)
check "XRANGE plus_stream 0-2 + -> last two entries" "$response" \
    "$(expect_xrange "0-2|bar|baz" "0-3|baz|foo")"

# ---------------------------------------------------------------------------
# Test 2: Inclusive start boundaries through the end
# ---------------------------------------------------------------------------
response=$(send_cmd XRANGE plus_stream 0-1 +)
check "XRANGE plus_stream 0-1 + -> all entries" "$response" \
    "$(expect_xrange "0-1|foo|bar" "0-2|bar|baz" "0-3|baz|foo")"

response=$(send_cmd XRANGE plus_stream 0-3 +)
check "XRANGE plus_stream 0-3 + -> only the last entry" "$response" \
    "$(expect_xrange "0-3|baz|foo")"

response=$(send_cmd XRANGE plus_stream 0 +)
check "XRANGE plus_stream 0 + -> all entries at and after millisecond 0" "$response" \
    "$(expect_xrange "0-1|foo|bar" "0-2|bar|baz" "0-3|baz|foo")"

response=$(send_cmd XRANGE plus_stream 0-4 +)
check "XRANGE plus_stream 0-4 + -> empty after last sequence" "$response" \
    "$(expect_empty_array)"

# ---------------------------------------------------------------------------
# Test 3: Missing and empty-result ranges
# ---------------------------------------------------------------------------
response=$(send_cmd XRANGE missing_plus_stream 0-1 +)
check "XRANGE missing stream 0-1 + -> empty array" "$response" \
    "$(expect_empty_array)"

send_cmd XADD early_stream 10-0 field value > /dev/null
send_cmd XADD early_stream 10-1 field next > /dev/null

response=$(send_cmd XRANGE early_stream 11-0 +)
check "XRANGE early_stream 11-0 + -> empty after stream tail" "$response" \
    "$(expect_empty_array)"

# ---------------------------------------------------------------------------
# Test 4: Multiple milliseconds and start IDs without sequence numbers
# ---------------------------------------------------------------------------
send_cmd XADD ms_plus_stream 100-0 a zero > /dev/null
send_cmd XADD ms_plus_stream 100-1 a one > /dev/null
send_cmd XADD ms_plus_stream 101-0 b two > /dev/null
send_cmd XADD ms_plus_stream 101-1 b three > /dev/null
send_cmd XADD ms_plus_stream 102-0 c four > /dev/null

response=$(send_cmd XRANGE ms_plus_stream 100 +)
check "XRANGE ms_plus_stream 100 + -> entire stream from first millisecond" "$response" \
    "$(expect_xrange "100-0|a|zero" "100-1|a|one" "101-0|b|two" "101-1|b|three" "102-0|c|four")"

response=$(send_cmd XRANGE ms_plus_stream 101 +)
check "XRANGE ms_plus_stream 101 + -> from millisecond 101 through tail" "$response" \
    "$(expect_xrange "101-0|b|two" "101-1|b|three" "102-0|c|four")"

response=$(send_cmd XRANGE ms_plus_stream 101-1 +)
check "XRANGE ms_plus_stream 101-1 + -> starts at exact sequence" "$response" \
    "$(expect_xrange "101-1|b|three" "102-0|c|four")"

response=$(send_cmd XRANGE ms_plus_stream 102-0 +)
check "XRANGE ms_plus_stream 102-0 + -> final millisecond only" "$response" \
    "$(expect_xrange "102-0|c|four")"

# ---------------------------------------------------------------------------
# Test 5: Preserve ordered field-value arrays when using '+' end
# ---------------------------------------------------------------------------
send_cmd XADD complex_plus_stream 200-0 temperature 36 humidity 95 status ok > /dev/null
send_cmd XADD complex_plus_stream 200-1 humidity 94 temperature 37 status warn > /dev/null
send_cmd XADD complex_plus_stream 201-0 "field name" "value with spaces" empty "" > /dev/null

response=$(send_cmd XRANGE complex_plus_stream 200-1 +)
check "XRANGE complex_plus_stream 200-1 + -> preserves fields, values, and order" "$response" \
    "$(expect_xrange \
        "200-1|humidity|94|temperature|37|status|warn" \
        "201-0|field name|value with spaces|empty|")"

# ---------------------------------------------------------------------------
# Test 6: Large stream, many entries, and several ranges through '+'
# ---------------------------------------------------------------------------
add_range_entries big_plus_stream 500 0 119

response=$(send_cmd XRANGE big_plus_stream 500-119 +)
check "XRANGE big_plus_stream 500-119 + -> last entry only" "$response" \
    "$(expected_range_entries 500 119 119)"

response=$(send_cmd XRANGE big_plus_stream 500-110 +)
check "XRANGE big_plus_stream 500-110 + -> last ten entries" "$response" \
    "$(expected_range_entries 500 110 119)"

response=$(send_cmd XRANGE big_plus_stream 500-70 +)
check "XRANGE big_plus_stream 500-70 + -> final fifty entries" "$response" \
    "$(expected_range_entries 500 70 119)"

response=$(send_cmd XRANGE big_plus_stream 500-0 +)
check "XRANGE big_plus_stream 500-0 + -> all 120 entries" "$response" \
    "$(expected_range_entries 500 0 119)"

response=$(send_cmd XRANGE big_plus_stream 501 +)
check "XRANGE big_plus_stream 501 + -> empty after large stream tail" "$response" \
    "$(expect_empty_array)"

# ---------------------------------------------------------------------------
# Test 7: Multiple streams remain independent when '+' is used
# ---------------------------------------------------------------------------
send_cmd XADD alpha_plus_stream 1-0 stream alpha > /dev/null
send_cmd XADD alpha_plus_stream 1-1 stream alpha_next > /dev/null
send_cmd XADD beta_plus_stream 1-0 stream beta > /dev/null
send_cmd XADD beta_plus_stream 1-1 stream beta_next > /dev/null

response=$(send_cmd XRANGE alpha_plus_stream 1-1 +)
check "XRANGE alpha_plus_stream 1-1 + -> only alpha tail" "$response" \
    "$(expect_xrange "1-1|stream|alpha_next")"

response=$(send_cmd XRANGE beta_plus_stream 1-0 +)
check "XRANGE beta_plus_stream 1-0 + -> only beta entries" "$response" \
    "$(expect_xrange "1-0|stream|beta" "1-1|stream|beta_next")"

# ---------------------------------------------------------------------------
# Test 8: Partial-auto and full-auto IDs are included through the end
# ---------------------------------------------------------------------------
send_cmd XADD auto_plus_stream 600-0 explicit zero > /dev/null
response=$(send_cmd XADD auto_plus_stream 600-* partial auto)
check "XADD auto_plus_stream 600-* -> 600-1" "$response" "$(expect_bulk 600-1)"

auto_response=$(send_cmd XADD auto_plus_stream "*" full auto)
auto_id=$(printf '%s' "$auto_response" | tr -d '\r' | sed -n '2p')

if [[ "$auto_id" =~ ^[0-9]+-[0-9]+$ ]]; then
    response=$(send_cmd XRANGE auto_plus_stream 600 +)
    check "XRANGE auto_plus_stream 600 + -> explicit and partial-auto entries plus later IDs" "$response" \
        "$(expect_xrange "600-0|explicit|zero" "600-1|partial|auto" "$auto_id|full|auto")"

    response=$(send_cmd XRANGE auto_plus_stream "$auto_id" +)
    check "XRANGE auto_plus_stream full-auto-id + -> starts at auto ID" "$response" \
        "$(expect_xrange "$auto_id|full|auto")"
else
    fail "XRANGE auto_plus_stream 600 + and full-auto-id +"
    fail "  skipped because XADD * did not return a valid ID: $(printf '%s' "$auto_response" | cat -A)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---------------------------------------------------------------------------
# Test 9: Case-insensitive XRANGE command with '+' end
# ---------------------------------------------------------------------------
response=$(send_cmd xrange plus_stream 0-3 +)
check "xrange lowercase command with '+' -> last entry" "$response" \
    "$(expect_xrange "0-3|baz|foo")"

response=$(send_cmd XrAnGe plus_stream 0-1 +)
check "XrAnGe mixed-case command with '+' -> all entries" "$response" \
    "$(expect_xrange "0-1|foo|bar" "0-2|bar|baz" "0-3|baz|foo")"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 21 passed."
else
    exit 1
fi
