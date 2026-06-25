#!/bin/bash
# Stage 24/25/26: Verify XREAD BLOCK with finite, indefinite, and "$" cursors

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
XREAD_BLOCKING_TEST_LOG="${XREAD_BLOCKING_TEST_LOG:-$TESTS_DIR/test_xread_blocking_output.log}"
: > "$XREAD_BLOCKING_TEST_LOG"
exec > >(tee -a "$XREAD_BLOCKING_TEST_LOG") 2>&1

source "$TESTS_DIR/helpers.sh"

echo "=== Stage 24/25/26: XREAD blocking queries ==="
info "Writing a copy of this test output to $XREAD_BLOCKING_TEST_LOG"

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0
TMPDIR_LOCAL=$(mktemp -d)

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
    timeout 8 nc -q 1 127.0.0.1 6379 < "$tmp" 2>/dev/null
    rm -f "$tmp"
}

start_xread() {
    local outfile="$1"
    shift
    (
        {
            write_resp_command "$@"
            sleep 8
        } | timeout 9 nc 127.0.0.1 6379 > "$outfile" 2>/dev/null
    ) &
    XREAD_PID=$!
}

wait_for_response() {
    local file="$1" attempts="${2:-40}" i
    for i in $(seq 1 "$attempts"); do
        [ -s "$file" ] && return 0
        sleep 0.1
    done
    return 1
}

cleanup_client() {
    local pid="$1"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    fi
}

cleanup_tmpdir() {
    rm -rf "$TMPDIR_LOCAL"
}

trap 'cleanup_tmpdir; stop_server' EXIT

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

check_no_response() {
    local label="$1" file="$2"
    if [ ! -s "$file" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  got unexpected response: $(cat "$file" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# $() strips trailing \n, so generated expected responses end with \r
expect_bulk()       { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_null_array() { printf '*-1\r'; }
expect_error()      { printf -- '-%s\r' "$1"; }

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
        if [[ "$spec" == *'|' ]]; then
            spec="${spec}__XREAD_BLOCKING_EMPTY_SENTINEL__"
        fi

        IFS='|' read -r -a parts <<< "$spec"
        id="${parts[0]}"
        kv_count=$((${#parts[@]} - 1))

        printf '*2\r\n'
        bulk_line "$id"
        printf '*%d\r\n' "$kv_count"
        for token in "${parts[@]:1}"; do
            if [ "$token" = "__XREAD_BLOCKING_EMPTY_SENTINEL__" ]; then
                token=""
            fi
            bulk_line "$token"
        done
    done
}

append_xread_stream() {
    local stream="$1"
    shift

    printf '*2\r\n'
    bulk_line "$stream"
    printf '*%d\r\n' "$#"

    local spec id kv_count token
    for spec in "$@"; do
        if [[ "$spec" == *'|' ]]; then
            spec="${spec}__XREAD_BLOCKING_MULTI_EMPTY_SENTINEL__"
        fi

        IFS='|' read -r -a parts <<< "$spec"
        id="${parts[0]}"
        kv_count=$((${#parts[@]} - 1))

        printf '*2\r\n'
        bulk_line "$id"
        printf '*%d\r\n' "$kv_count"
        for token in "${parts[@]:1}"; do
            if [ "$token" = "__XREAD_BLOCKING_MULTI_EMPTY_SENTINEL__" ]; then
                token=""
            fi
            bulk_line "$token"
        done
    done
}

split_entry_specs() {
    local entries_string="$1"
    local -n out_entries="$2"

    out_entries=()
    while [[ "$entries_string" == *';;'* ]]; do
        out_entries+=("${entries_string%%;;*}")
        entries_string="${entries_string#*;;}"
    done
    out_entries+=("$entries_string")
}

# Each stream group is encoded as:
#   "stream_name::id|field|value;;id|field|value"
expect_xread_multi() {
    if [ "$#" -eq 0 ]; then
        expect_null_array
        return
    fi

    local group stream entries_string
    local non_empty_groups=()
    for group in "$@"; do
        stream="${group%%::*}"
        entries_string="${group#*::}"
        if [ -n "$stream" ] && [ -n "$entries_string" ]; then
            non_empty_groups+=("$group")
        fi
    done

    if [ "${#non_empty_groups[@]}" -eq 0 ]; then
        expect_null_array
        return
    fi

    printf '*%d\r\n' "${#non_empty_groups[@]}"
    for group in "${non_empty_groups[@]}"; do
        stream="${group%%::*}"
        entries_string="${group#*::}"

        split_entry_specs "$entries_string" entries
        append_xread_stream "$stream" "${entries[@]}"
    done
}

join_specs() {
    local first=1 spec
    for spec in "$@"; do
        if [ "$first" -eq 1 ]; then
            printf '%s' "$spec"
            first=0
        else
            printf ';;%s' "$spec"
        fi
    done
}

add_numbered_entries() {
    local stream="$1" ms="$2" start="$3" end="$4" id
    for id in $(seq "$start" "$end"); do
        send_cmd XADD "$stream" "$ms-$id" idx "$id" bucket "$((id / 25))" parity "$((id % 2))" payload "${stream}_value_$id" > /dev/null
    done
}

numbered_specs() {
    local stream="$1" ms="$2" start="$3" end="$4" id
    local specs=()
    for id in $(seq "$start" "$end"); do
        specs+=("$ms-$id|idx|$id|bucket|$((id / 25))|parity|$((id % 2))|payload|${stream}_value_$id")
    done
    join_specs "${specs[@]}"
}

expected_numbered_xread() {
    local stream="$1" ms="$2" start="$3" end="$4" id
    local specs=()
    for id in $(seq "$start" "$end"); do
        specs+=("$ms-$id|idx|$id|bucket|$((id / 25))|parity|$((id % 2))|payload|${stream}_value_$id")
    done
    expect_xread "$stream" "${specs[@]}"
}

# ---------------------------------------------------------------------------
# Test 1: BLOCK returns immediately when entries are already available
# ---------------------------------------------------------------------------
response=$(send_cmd XADD block_ready_stream 0-1 temperature 96)
check "XADD block_ready_stream 0-1 -> bulk ID" "$response" "$(expect_bulk 0-1)"

response=$(send_cmd XADD block_ready_stream 0-2 temperature 95)
check "XADD block_ready_stream 0-2 -> bulk ID" "$response" "$(expect_bulk 0-2)"

response=$(send_cmd XREAD BLOCK 1000 STREAMS block_ready_stream 0-1)
check "XREAD BLOCK returns immediately for existing newer entry" "$response" \
    "$(expect_xread block_ready_stream "0-2|temperature|95")"

# ---------------------------------------------------------------------------
# Test 2: Finite BLOCK waits, then wakes when XADD appends a new entry
# ---------------------------------------------------------------------------
send_cmd XADD block_wake_stream 0-1 temperature 96 > /dev/null

RESP_WAKE="$TMPDIR_LOCAL/xread_block_wake"
start_xread "$RESP_WAKE" XREAD BLOCK 1000 STREAMS block_wake_stream 0-1
PID_WAKE=$XREAD_PID

sleep 0.3
check_no_response "XREAD BLOCK has no response before a new stream entry" "$RESP_WAKE"

response=$(send_cmd XADD block_wake_stream 0-2 temperature 95)
check "XADD block_wake_stream 0-2 wakes blocked XREAD" "$response" "$(expect_bulk 0-2)"

if wait_for_response "$RESP_WAKE"; then
    response=$(cat "$RESP_WAKE")
    check "Blocked XREAD receives the newly appended entry" "$response" \
        "$(expect_xread block_wake_stream "0-2|temperature|95")"
else
    fail "Blocked XREAD did not receive response after XADD"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_client "$PID_WAKE"

# ---------------------------------------------------------------------------
# Test 3: Finite BLOCK returns a null array when the timeout elapses
# ---------------------------------------------------------------------------
RESP_TIMEOUT="$TMPDIR_LOCAL/xread_block_timeout"
start_xread "$RESP_TIMEOUT" XREAD block 1000 streams block_wake_stream 0-2
PID_TIMEOUT=$XREAD_PID

if wait_for_response "$RESP_TIMEOUT" 25; then
    response=$(cat "$RESP_TIMEOUT")
    check "XREAD BLOCK timeout returns null array" "$response" "$(expect_null_array)"
else
    fail "XREAD BLOCK timeout did not respond with a null array"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_client "$PID_TIMEOUT"

# ---------------------------------------------------------------------------
# Test 4: BLOCK 0 waits indefinitely until a new entry arrives
# ---------------------------------------------------------------------------
send_cmd XADD block_forever_stream 0-1 temperature 96 > /dev/null

RESP_FOREVER="$TMPDIR_LOCAL/xread_block_forever"
start_xread "$RESP_FOREVER" XREAD BLOCK 0 STREAMS block_forever_stream 0-1
PID_FOREVER=$XREAD_PID

sleep 1
check_no_response "XREAD BLOCK 0 remains blocked after 1000ms" "$RESP_FOREVER"

response=$(send_cmd XADD block_forever_stream 0-2 temperature 95)
check "XADD block_forever_stream 0-2 wakes BLOCK 0 XREAD" "$response" "$(expect_bulk 0-2)"

if wait_for_response "$RESP_FOREVER"; then
    response=$(cat "$RESP_FOREVER")
    check "XREAD BLOCK 0 receives the newly appended entry" "$response" \
        "$(expect_xread block_forever_stream "0-2|temperature|95")"
else
    fail "XREAD BLOCK 0 did not receive response after XADD"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_client "$PID_FOREVER"

# ---------------------------------------------------------------------------
# Test 5: BLOCK with "$" only returns entries added after the command starts
# ---------------------------------------------------------------------------
send_cmd XADD block_dollar_stream 0-1 temperature 96 > /dev/null

RESP_DOLLAR="$TMPDIR_LOCAL/xread_block_dollar"
start_xread "$RESP_DOLLAR" XREAD BLOCK 0 STREAMS block_dollar_stream '$'
PID_DOLLAR=$XREAD_PID

sleep 0.5
check_no_response "XREAD BLOCK 0 with $ ignores existing tail entry" "$RESP_DOLLAR"

response=$(send_cmd XADD block_dollar_stream 0-2 temperature 95)
check "XADD block_dollar_stream 0-2 wakes XREAD BLOCK 0 $" "$response" "$(expect_bulk 0-2)"

if wait_for_response "$RESP_DOLLAR"; then
    response=$(cat "$RESP_DOLLAR")
    check "XREAD BLOCK 0 with $ receives only the entry added after blocking" "$response" \
        "$(expect_xread block_dollar_stream "0-2|temperature|95")"
else
    fail "XREAD BLOCK 0 with $ did not receive response after XADD"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_client "$PID_DOLLAR"

# ---------------------------------------------------------------------------
# Test 6: Finite BLOCK with "$" returns null when no new entry arrives
# ---------------------------------------------------------------------------
RESP_DOLLAR_TIMEOUT="$TMPDIR_LOCAL/xread_block_dollar_timeout"
start_xread "$RESP_DOLLAR_TIMEOUT" XREAD BLOCK 1000 STREAMS block_dollar_stream '$'
PID_DOLLAR_TIMEOUT=$XREAD_PID

sleep 0.4
check_no_response "XREAD BLOCK 1000 with $ remains blocked before timeout" "$RESP_DOLLAR_TIMEOUT"

if wait_for_response "$RESP_DOLLAR_TIMEOUT" 25; then
    response=$(cat "$RESP_DOLLAR_TIMEOUT")
    check "XREAD BLOCK 1000 with $ times out with null array" "$response" "$(expect_null_array)"
else
    fail "XREAD BLOCK 1000 with $ did not time out with a null array"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_client "$PID_DOLLAR_TIMEOUT"

# ---------------------------------------------------------------------------
# Test 7: Large single stream reads with BLOCK and several different cursors
# ---------------------------------------------------------------------------
add_numbered_entries block_big_stream 5000 0 219

response=$(send_cmd XREAD BLOCK 1000 STREAMS block_big_stream 5000-149)
check "XREAD BLOCK large stream from 5000-149 -> final 70 entries" "$response" \
    "$(expected_numbered_xread block_big_stream 5000 150 219)"

response=$(send_cmd XREAD BLOCK 1000 STREAMS block_big_stream 5000-198)
check "XREAD BLOCK large stream from 5000-198 -> final 21 entries" "$response" \
    "$(expected_numbered_xread block_big_stream 5000 199 219)"

response=$(send_cmd XREAD BLOCK 1000 STREAMS block_big_stream 5000-218)
check "XREAD BLOCK large stream from 5000-218 -> last entry only" "$response" \
    "$(expect_xread block_big_stream "5000-219|idx|219|bucket|8|parity|1|payload|block_big_stream_value_219")"

response=$(send_cmd XREAD BLOCK 50 STREAMS block_big_stream 5000-219)
check "XREAD BLOCK large stream at tail -> null array after short timeout" "$response" \
    "$(expect_null_array)"

# ---------------------------------------------------------------------------
# Test 8: Large multi-stream BLOCK preserves request order and cursor choices
# ---------------------------------------------------------------------------
add_numbered_entries block_multi_a 6000 0 79
add_numbered_entries block_multi_b 7000 0 109
add_numbered_entries block_multi_c 8000 0 49

response=$(send_cmd XREAD BLOCK 1000 STREAMS block_multi_c block_multi_a block_multi_b 8000-44 6000-70 7000-105)
check "XREAD BLOCK large multi-stream tails with different cursors" "$response" \
    "$(expect_xread_multi \
        "block_multi_c::$(numbered_specs block_multi_c 8000 45 49)" \
        "block_multi_a::$(numbered_specs block_multi_a 6000 71 79)" \
        "block_multi_b::$(numbered_specs block_multi_b 7000 106 109)")"

response=$(send_cmd XREAD BLOCK 50 STREAMS block_multi_a block_multi_b block_multi_c 6000-79 7000-109 8000-49)
check "XREAD BLOCK large multi-stream at every tail -> null array after short timeout" "$response" \
    "$(expect_null_array)"

# ---------------------------------------------------------------------------
# Test 9: Multi-stream blocking wakes on one stream and omits still-empty tails
# ---------------------------------------------------------------------------
send_cmd XADD block_wait_a 10-0 source a0 > /dev/null
send_cmd XADD block_wait_b 20-0 source b0 > /dev/null
send_cmd XADD block_wait_c 30-0 source c0 > /dev/null

RESP_MULTI_WAKE="$TMPDIR_LOCAL/xread_block_multi_wake"
start_xread "$RESP_MULTI_WAKE" XREAD BLOCK 1000 STREAMS block_wait_a block_wait_b block_wait_c 10-0 20-0 30-0
PID_MULTI_WAKE=$XREAD_PID

sleep 0.3
check_no_response "XREAD BLOCK multi-stream waits while all streams are at tail" "$RESP_MULTI_WAKE"

response=$(send_cmd XADD block_wait_b 20-1 source b1 marker wake)
check "XADD to second stream wakes multi-stream XREAD" "$response" "$(expect_bulk 20-1)"

if wait_for_response "$RESP_MULTI_WAKE"; then
    response=$(cat "$RESP_MULTI_WAKE")
    check "XREAD BLOCK multi-stream returns only the stream with new entries" "$response" \
        "$(expect_xread_multi "block_wait_b::20-1|source|b1|marker|wake")"
else
    fail "XREAD BLOCK multi-stream did not receive response after XADD"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_client "$PID_MULTI_WAKE"

# ---------------------------------------------------------------------------
# Test 10: Blocking on a missing stream wakes when XADD creates that stream
# ---------------------------------------------------------------------------
RESP_MISSING_WAKE="$TMPDIR_LOCAL/xread_block_missing_wake"
start_xread "$RESP_MISSING_WAKE" XREAD BLOCK 1000 STREAMS block_missing_created 0-0
PID_MISSING_WAKE=$XREAD_PID

sleep 0.3
check_no_response "XREAD BLOCK waits on a stream that does not exist yet" "$RESP_MISSING_WAKE"

response=$(send_cmd XADD block_missing_created 0-1 created yes)
check "XADD creates missing stream and wakes XREAD BLOCK" "$response" "$(expect_bulk 0-1)"

if wait_for_response "$RESP_MISSING_WAKE"; then
    response=$(cat "$RESP_MISSING_WAKE")
    check "XREAD BLOCK missing stream receives first created entry" "$response" \
        "$(expect_xread block_missing_created "0-1|created|yes")"
else
    fail "XREAD BLOCK missing stream did not receive response after XADD"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_client "$PID_MISSING_WAKE"

# ---------------------------------------------------------------------------
# Test 11: Multiple blocked XREAD clients on the same stream all observe data
# ---------------------------------------------------------------------------
send_cmd XADD block_fanout_stream 42-0 seed value > /dev/null

RESP_FANOUT_ONE="$TMPDIR_LOCAL/xread_block_fanout_one"
RESP_FANOUT_TWO="$TMPDIR_LOCAL/xread_block_fanout_two"

start_xread "$RESP_FANOUT_ONE" XREAD BLOCK 1000 STREAMS block_fanout_stream 42-0
PID_FANOUT_ONE=$XREAD_PID
sleep 0.2
start_xread "$RESP_FANOUT_TWO" XREAD BLOCK 1000 STREAMS block_fanout_stream 42-0
PID_FANOUT_TWO=$XREAD_PID

sleep 0.3
check_no_response "First XREAD fanout client is blocked before XADD" "$RESP_FANOUT_ONE"
check_no_response "Second XREAD fanout client is blocked before XADD" "$RESP_FANOUT_TWO"

response=$(send_cmd XADD block_fanout_stream 42-1 fanout value)
check "XADD wakes every blocked XREAD client for the stream" "$response" "$(expect_bulk 42-1)"

if wait_for_response "$RESP_FANOUT_ONE"; then
    response=$(cat "$RESP_FANOUT_ONE")
    check "First blocked XREAD client receives fanout entry" "$response" \
        "$(expect_xread block_fanout_stream "42-1|fanout|value")"
else
    fail "First blocked XREAD fanout client did not receive response"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if wait_for_response "$RESP_FANOUT_TWO"; then
    response=$(cat "$RESP_FANOUT_TWO")
    check "Second blocked XREAD client receives fanout entry" "$response" \
        "$(expect_xread block_fanout_stream "42-1|fanout|value")"
else
    fail "Second blocked XREAD fanout client did not receive response"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_client "$PID_FANOUT_ONE"
cleanup_client "$PID_FANOUT_TWO"

# ---------------------------------------------------------------------------
# Test 12: Blocking response preserves complex field/value arrays
# ---------------------------------------------------------------------------
send_cmd XADD block_complex_stream 99-0 seed value > /dev/null

RESP_COMPLEX="$TMPDIR_LOCAL/xread_block_complex"
start_xread "$RESP_COMPLEX" XREAD BLOCK 1000 STREAMS block_complex_stream 99-0
PID_COMPLEX=$XREAD_PID

sleep 0.3
check_no_response "XREAD BLOCK complex payload waits before XADD" "$RESP_COMPLEX"

response=$(send_cmd XADD block_complex_stream 100-0 "field name" "value with spaces" empty "" repeated one repeated two punctuation "a:b,c.d")
check "XADD complex stream entry wakes blocked XREAD" "$response" "$(expect_bulk 100-0)"

if wait_for_response "$RESP_COMPLEX"; then
    response=$(cat "$RESP_COMPLEX")
    check "XREAD BLOCK preserves spaces, empty values, repeated fields, and punctuation" "$response" \
        "$(expect_xread block_complex_stream "100-0|field name|value with spaces|empty||repeated|one|repeated|two|punctuation|a:b,c.d")"
else
    fail "XREAD BLOCK complex payload did not receive response"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_client "$PID_COMPLEX"

# ---------------------------------------------------------------------------
# Test 13: Invalid and empty BLOCK argument shapes
# ---------------------------------------------------------------------------
response=$(send_cmd XREAD BLOCK)
check "XREAD BLOCK with no timeout or streams -> wrong number error" "$response" \
    "$(expect_error "ERR wrong number of arguments.")"

response=$(send_cmd XREAD BLOCK abc STREAMS block_ready_stream 0-0)
check "XREAD BLOCK with non-integer timeout -> timeout integer error" "$response" \
    "$(expect_error "ERR timeout is not an integer or out of range")"

response=$(send_cmd XREAD BLOCK -1 STREAMS block_ready_stream 0-0)
check "XREAD BLOCK with negative timeout -> timeout negative error" "$response" \
    "$(expect_error "ERR timeout is negative")"

response=$(send_cmd XREAD BLOCK 1000 notstreams block_ready_stream 0-0)
check "XREAD BLOCK without STREAMS keyword -> syntax error" "$response" \
    "$(expect_error "ERR syntax error")"

response=$(send_cmd XREAD BLOCK 1000 STREAMS block_wait_a block_wait_b 10-0)
check "XREAD BLOCK uneven key/id count -> wrong number error" "$response" \
    "$(expect_error "ERR wrong number of arguments.")"

send_cmd SET block_wrong_type value > /dev/null
response=$(send_cmd XREAD BLOCK 1000 STREAMS block_wrong_type 0-0)
check "XREAD BLOCK wrong-type key -> WRONGTYPE error" "$response" \
    "$(expect_error "WRONGTYPE Operation against a key holding the wrong kind of value")"

# ---------------------------------------------------------------------------
cleanup_tmpdir
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 24/25/26 passed."
else
    exit 1
fi
