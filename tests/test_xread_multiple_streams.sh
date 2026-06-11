#!/bin/bash
# Stage 23: Verify XREAD queries multiple streams and preserves request order

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
XREAD_MULTI_TEST_LOG="${XREAD_MULTI_TEST_LOG:-$TESTS_DIR/test_xread_multiple_streams_output.log}"
: > "$XREAD_MULTI_TEST_LOG"
exec > >(tee -a "$XREAD_MULTI_TEST_LOG") 2>&1

source "$TESTS_DIR/helpers.sh"

echo "=== Stage 23: XREAD multiple stream queries ==="
info "Writing a copy of this test output to $XREAD_MULTI_TEST_LOG"

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
    timeout 8 nc -q 1 127.0.0.1 6379 < "$tmp" 2>/dev/null
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
expect_null_array() { printf '*-1\r'; }
expect_error()      { printf -- '-%s\r' "$1"; }

bulk_line() {
    printf '$%d\r\n%s\r\n' "${#1}" "$1"
}

append_xread_stream() {
    local stream="$1"
    shift

    printf '*2\r\n'
    bulk_line "$stream"
    printf '*%d\r\n' "$#"

    local spec id kv_count token
    for spec in "$@"; do
        # Preserve a trailing empty token so specs like "id|field|" include
        # the empty bulk string in the expected RESP array.
        if [[ "$spec" == *'|' ]]; then
            spec="${spec}__XREAD_MULTI_EMPTY_SENTINEL__"
        fi

        IFS='|' read -r -a parts <<< "$spec"
        id="${parts[0]}"
        kv_count=$((${#parts[@]} - 1))

        printf '*2\r\n'
        bulk_line "$id"
        printf '*%d\r\n' "$kv_count"
        for token in "${parts[@]:1}"; do
            if [ "$token" = "__XREAD_MULTI_EMPTY_SENTINEL__" ]; then
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
# The stream is included only when it has at least one returned entry.
expect_xread_multi() {
    if [ "$#" -eq 0 ]; then
        expect_null_array
        return
    fi

    local group stream entries_string entry
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
        send_cmd XADD "$stream" "$ms-$id" idx "$id" bucket "$((id / 20))" parity "$((id % 2))" payload "${stream}_value_$id" > /dev/null
    done
}

numbered_specs() {
    local stream="$1" ms="$2" start="$3" end="$4" id
    local specs=()
    for id in $(seq "$start" "$end"); do
        specs+=("$ms-$id|idx|$id|bucket|$((id / 20))|parity|$((id % 2))|payload|${stream}_value_$id")
    done
    join_specs "${specs[@]}"
}

# ---------------------------------------------------------------------------
# Test 1: Codecrafters-style example with two streams
# ---------------------------------------------------------------------------
response=$(send_cmd XADD stream_key 0-1 temperature 95)
check "XADD stream_key 0-1 -> bulk ID" "$response" "$(expect_bulk 0-1)"

response=$(send_cmd XADD other_stream_key 0-2 humidity 97)
check "XADD other_stream_key 0-2 -> bulk ID" "$response" "$(expect_bulk 0-2)"

response=$(send_cmd XREAD STREAMS stream_key other_stream_key 0-0 0-1)
check "XREAD two streams -> one result per stream in request order" "$response" \
    "$(expect_xread_multi \
        "stream_key::0-1|temperature|95" \
        "other_stream_key::0-2|humidity|97")"

# ---------------------------------------------------------------------------
# Test 2: Response order follows command order, not insertion order
# ---------------------------------------------------------------------------
send_cmd XADD order_a 1-0 source a0 > /dev/null
send_cmd XADD order_a 1-1 source a1 > /dev/null
send_cmd XADD order_b 1-0 source b0 > /dev/null
send_cmd XADD order_b 1-1 source b1 > /dev/null
send_cmd XADD order_c 1-0 source c0 > /dev/null
send_cmd XADD order_c 1-1 source c1 > /dev/null

response=$(send_cmd XREAD STREAMS order_c order_a order_b 1-0 0-0 1-0)
check "XREAD preserves requested stream order with different start IDs" "$response" \
    "$(expect_xread_multi \
        "order_c::1-1|source|c1" \
        "order_a::1-0|source|a0;;1-1|source|a1" \
        "order_b::1-1|source|b1")"

response=$(send_cmd XREAD STREAMS order_b order_c order_a 0-0 1-1 1-0)
check "XREAD omits streams without new entries but preserves remaining order" "$response" \
    "$(expect_xread_multi \
        "order_b::1-0|source|b0;;1-1|source|b1" \
        "order_a::1-1|source|a1")"

# ---------------------------------------------------------------------------
# Test 3: All streams empty/missing/no newer entries returns a null array
# ---------------------------------------------------------------------------
response=$(send_cmd XREAD STREAMS missing_multi_a missing_multi_b 0-0 9-9)
check "XREAD multiple missing streams -> null array" "$response" "$(expect_null_array)"

response=$(send_cmd XREAD STREAMS order_a order_b order_c 1-1 1-1 1-1)
check "XREAD multiple streams at tail -> null array" "$response" "$(expect_null_array)"

# ---------------------------------------------------------------------------
# Test 4: Mixture of valid streams and missing streams
# ---------------------------------------------------------------------------
send_cmd XADD mix_stream_a 10-0 field a0 > /dev/null
send_cmd XADD mix_stream_a 10-1 field a1 > /dev/null
send_cmd XADD mix_stream_b 10-0 field b0 > /dev/null
send_cmd XADD mix_stream_b 10-1 field b1 > /dev/null

response=$(send_cmd XREAD STREAMS missing_multi_d mix_stream_b missing_multi_e mix_stream_a 0-0 10-0 0-0 10-0)
check "XREAD skips missing streams and returns valid streams in order" "$response" \
    "$(expect_xread_multi \
        "mix_stream_b::10-1|field|b1" \
        "mix_stream_a::10-1|field|a1")"

# ---------------------------------------------------------------------------
# Test 5: Complex field-value arrays across several streams
# ---------------------------------------------------------------------------
send_cmd XADD complex_a 20-0 temperature 36 humidity 95 status ok > /dev/null
send_cmd XADD complex_a 20-1 "field name" "value with spaces" empty "" > /dev/null
send_cmd XADD complex_b 30-0 123 456 punctuation "a:b,c.d" > /dev/null
send_cmd XADD complex_b 30-1 repeated one repeated two > /dev/null
send_cmd XADD complex_c 40-0 alpha beta gamma delta epsilon zeta > /dev/null

response=$(send_cmd XREAD STREAMS complex_b complex_c complex_a 29-999 0-0 20-0)
check "XREAD multiple streams preserves field order, spaces, empty values, and numeric fields" "$response" \
    "$(expect_xread_multi \
        "complex_b::30-0|123|456|punctuation|a:b,c.d;;30-1|repeated|one|repeated|two" \
        "complex_c::40-0|alpha|beta|gamma|delta|epsilon|zeta" \
        "complex_a::20-1|field name|value with spaces|empty|")"

# ---------------------------------------------------------------------------
# Test 6: IDs without sequence numbers are exclusive by whole millisecond
# ---------------------------------------------------------------------------
send_cmd XADD ms_multi_a 100-0 a zero > /dev/null
send_cmd XADD ms_multi_a 100-1 a one > /dev/null
send_cmd XADD ms_multi_a 101-0 a two > /dev/null
send_cmd XADD ms_multi_b 100-0 b zero > /dev/null
send_cmd XADD ms_multi_b 101-0 b one > /dev/null
send_cmd XADD ms_multi_b 102-0 b two > /dev/null

response=$(send_cmd XREAD STREAMS ms_multi_a ms_multi_b 100 101)
check "XREAD partial IDs exclude all entries at the supplied millisecond" "$response" \
    "$(expect_xread_multi \
        "ms_multi_a::101-0|a|two" \
        "ms_multi_b::102-0|b|two")"

# ---------------------------------------------------------------------------
# Test 7: Large multi-stream read with different cursors per stream
# ---------------------------------------------------------------------------
add_numbered_entries big_multi_a 500 0 119
add_numbered_entries big_multi_b 600 0 89
add_numbered_entries big_multi_c 700 0 64

response=$(send_cmd XREAD STREAMS big_multi_a big_multi_b big_multi_c 499-999 600-79 700-59)
check "XREAD large streams -> all of A, tail of B, tail of C" "$response" \
    "$(expect_xread_multi \
        "big_multi_a::$(numbered_specs big_multi_a 500 0 119)" \
        "big_multi_b::$(numbered_specs big_multi_b 600 80 89)" \
        "big_multi_c::$(numbered_specs big_multi_c 700 60 64)")"

response=$(send_cmd XREAD STREAMS big_multi_c big_multi_a big_multi_b 700-63 500-109 600-88)
check "XREAD large streams -> small tails in a different stream order" "$response" \
    "$(expect_xread_multi \
        "big_multi_c::$(numbered_specs big_multi_c 700 64 64)" \
        "big_multi_a::$(numbered_specs big_multi_a 500 110 119)" \
        "big_multi_b::$(numbered_specs big_multi_b 600 89 89)")"

response=$(send_cmd XREAD STREAMS big_multi_a big_multi_b big_multi_c 500-119 600-89 700-64)
check "XREAD large streams at every tail -> null array" "$response" "$(expect_null_array)"

# ---------------------------------------------------------------------------
# Test 8: Partial-auto and full-auto IDs in a multi-stream read
# ---------------------------------------------------------------------------
send_cmd XADD auto_multi_a 800-0 explicit a0 > /dev/null
response=$(send_cmd XADD auto_multi_a 800-* partial a1)
check "XADD auto_multi_a 800-* -> 800-1" "$response" "$(expect_bulk 800-1)"

send_cmd XADD auto_multi_b 900-0 explicit b0 > /dev/null
response=$(send_cmd XADD auto_multi_b 900-* partial b1)
check "XADD auto_multi_b 900-* -> 900-1" "$response" "$(expect_bulk 900-1)"

auto_response_a=$(send_cmd XADD auto_multi_a "*" full a2)
auto_id_a=$(printf '%s' "$auto_response_a" | tr -d '\r' | sed -n '2p')
auto_response_b=$(send_cmd XADD auto_multi_b "*" full b2)
auto_id_b=$(printf '%s' "$auto_response_b" | tr -d '\r' | sed -n '2p')

if [[ "$auto_id_a" =~ ^[0-9]+-[0-9]+$ && "$auto_id_b" =~ ^[0-9]+-[0-9]+$ ]]; then
    response=$(send_cmd XREAD STREAMS auto_multi_b auto_multi_a 900-0 800-1)
    check "XREAD multi-stream auto IDs -> returned IDs can be used as normal stream IDs" "$response" \
        "$(expect_xread_multi \
            "auto_multi_b::900-1|partial|b1;;$auto_id_b|full|b2" \
            "auto_multi_a::$auto_id_a|full|a2")"
else
    fail "XREAD multi-stream auto ID tests"
    fail "  skipped because generated IDs were invalid: A=$(printf '%s' "$auto_response_a" | cat -A), B=$(printf '%s' "$auto_response_b" | cat -A)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---------------------------------------------------------------------------
# Test 9: Case-insensitive command and STREAMS keyword
# ---------------------------------------------------------------------------
response=$(send_cmd xread streams order_a order_b 1-0 1-0)
check "xread lowercase command and streams keyword -> multi-stream response" "$response" \
    "$(expect_xread_multi \
        "order_a::1-1|source|a1" \
        "order_b::1-1|source|b1")"

response=$(send_cmd XrEaD StReAmS order_c order_a 1-0 0-0)
check "XrEaD mixed-case command and STREAMS keyword -> multi-stream response" "$response" \
    "$(expect_xread_multi \
        "order_c::1-1|source|c1" \
        "order_a::1-0|source|a0;;1-1|source|a1")"

# ---------------------------------------------------------------------------
# Test 10: Invalid argument shapes
# ---------------------------------------------------------------------------
response=$(send_cmd XREAD)
check "XREAD with no arguments -> wrong number error" "$response" \
    "$(expect_error "ERR wrong number of arguments.")"

response=$(send_cmd XREAD STREAMS)
check "XREAD STREAMS with no keys or IDs -> wrong number error" "$response" \
    "$(expect_error "ERR wrong number of arguments.")"

response=$(send_cmd XREAD notstreams order_a 0-0)
check "XREAD without STREAMS keyword -> syntax error" "$response" \
    "$(expect_error "ERR syntax error")"

response=$(send_cmd XREAD STREAMS order_a order_b 0-0)
check "XREAD uneven key/id count -> wrong number error" "$response" \
    "$(expect_error "ERR wrong number of arguments.")"

send_cmd SET not_a_stream value > /dev/null
response=$(send_cmd XREAD STREAMS not_a_stream 0-0)
check "XREAD wrong-type key -> WRONGTYPE error" "$response" \
    "$(expect_error "WRONGTYPE Operation against a key holding the wrong kind of value")"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 23 passed."
else
    exit 1
fi
