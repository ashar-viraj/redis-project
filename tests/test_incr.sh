#!/bin/bash
# Verify the server implements INCR with numeric, error, expiry, and blocking-adjacent cases

source "$(dirname "$0")/helpers.sh"

echo "=== Stage: INCR command ==="

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
    timeout 3 nc -q 1 -W 1 127.0.0.1 6379 < "$tmp" 2>/dev/null
    rm -f "$tmp"
}

send_sequential_connection() {
    {
        write_resp_command SET piped_counter 10
        sleep 0.1
        write_resp_command INCR piped_counter
        sleep 0.1
        write_resp_command INCR piped_counter
        sleep 0.1
        write_resp_command GET piped_counter
    } | timeout 4 nc -q 1 -W 4 127.0.0.1 6379 2>/dev/null
}

start_blpop() {
    local outfile="$1" key="$2"
    local timeout_seconds="${3:-0}"
    (
        {
            write_resp_command BLPOP "$key" "$timeout_seconds"
            sleep 8
        } | timeout 9 nc 127.0.0.1 6379 > "$outfile" 2>/dev/null
    ) &
    BLPOP_PID=$!
}

wait_for_response() {
    local file="$1" attempts="${2:-30}" i
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

# Command substitution strips trailing \n, so expected responses end with \r.
expect_ok()          { printf '+OK\r'; }
expect_int()         { printf ':%d\r' "$1"; }
expect_bulk()        { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_null()        { printf '$-1\r'; }
expect_null_array()  { printf '*-1\r'; }
expect_simple()      { printf '+%s\r' "$1"; }
expect_error()       { printf -- '-%s\r' "$1"; }
expect_incr_error()  { expect_error "ERR value is not an integer or out of range"; }
expect_wrong_arity() { expect_error "ERR wrong number of arguments."; }
expect_wrongtype()   { expect_error "WRONGTYPE Operation against a key holding the wrong kind of value"; }

expect_array() {
    local count=$# i=1
    printf '*%d\r\n' "$count"
    for word in "$@"; do
        if [ "$i" -eq "$count" ]; then
            printf '$%d\r\n%s\r' "${#word}" "$word"
        else
            printf '$%d\r\n%s\r\n' "${#word}" "$word"
        fi
        i=$((i + 1))
    done
}

# ---------------------------------------------------------------------------
# Test 1: Prompt baseline - existing numeric key increments and is persisted
# ---------------------------------------------------------------------------
response=$(send_cmd SET foo 41)
check "SET foo 41 -> +OK" "$response" "$(expect_ok)"

response=$(send_cmd INCR foo)
check "INCR foo -> :42" "$response" "$(expect_int 42)"

response=$(send_cmd GET foo)
check "GET foo after INCR -> 42" "$response" "$(expect_bulk 42)"

# ---------------------------------------------------------------------------
# Test 2: Missing keys are created at 1 and independent keys do not collide
# ---------------------------------------------------------------------------
response=$(send_cmd INCR abc)
check "INCR missing abc -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd INCR abc)
check "Second INCR abc -> :2" "$response" "$(expect_int 2)"

response=$(send_cmd INCR bar)
check "INCR different missing key bar -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd GET abc)
check "GET abc after two INCRs -> 2" "$response" "$(expect_bulk 2)"

response=$(send_cmd GET bar)
check "GET bar after one INCR -> 1" "$response" "$(expect_bulk 1)"

# ---------------------------------------------------------------------------
# Test 3: Zero, negative, leading-plus, and leading-zero integers
# ---------------------------------------------------------------------------
send_cmd SET zero_counter 0 > /dev/null
response=$(send_cmd INCR zero_counter)
check "INCR 0 -> :1" "$response" "$(expect_int 1)"

send_cmd SET neg_one -1 > /dev/null
response=$(send_cmd INCR neg_one)
check "INCR -1 -> :0" "$response" "$(expect_int 0)"

send_cmd SET negative_counter -42 > /dev/null
response=$(send_cmd INCR negative_counter)
check "INCR -42 -> :-41" "$response" "$(expect_int -41)"

send_cmd SET plus_counter +5 > /dev/null
response=$(send_cmd INCR plus_counter)
check "INCR +5 -> :6" "$response" "$(expect_int 6)"

send_cmd SET leading_zero_counter 0009 > /dev/null
response=$(send_cmd INCR leading_zero_counter)
check "INCR 0009 -> :10" "$response" "$(expect_int 10)"

response=$(send_cmd GET leading_zero_counter)
check "GET leading_zero_counter normalizes stored value to 10" "$response" "$(expect_bulk 10)"

# ---------------------------------------------------------------------------
# Test 4: 64-bit boundaries
# ---------------------------------------------------------------------------
send_cmd SET near_max 9223372036854775806 > /dev/null
response=$(send_cmd INCR near_max)
check "INCR LLONG_MAX - 1 -> LLONG_MAX" "$response" "$(expect_int 9223372036854775807)"

send_cmd SET max_counter 9223372036854775807 > /dev/null
response=$(send_cmd INCR max_counter)
check "INCR LLONG_MAX -> integer/out-of-range error" "$response" "$(expect_incr_error)"

response=$(send_cmd GET max_counter)
check "Overflowing INCR leaves original LLONG_MAX value" "$response" \
    "$(expect_bulk 9223372036854775807)"

send_cmd SET min_counter -9223372036854775808 > /dev/null
response=$(send_cmd INCR min_counter)
check "INCR LLONG_MIN -> LLONG_MIN + 1" "$response" "$(expect_int -9223372036854775807)"

# ---------------------------------------------------------------------------
# Test 5: Non-numeric string values return the required INCR error
# ---------------------------------------------------------------------------
send_cmd SET check xyz > /dev/null
response=$(send_cmd INCR check)
check "INCR alphabetic string -> integer/out-of-range error" "$response" "$(expect_incr_error)"

response=$(send_cmd GET check)
check "Failed INCR keeps original alphabetic value" "$response" "$(expect_bulk xyz)"

send_cmd SET empty_value "" > /dev/null
response=$(send_cmd INCR empty_value)
check "INCR empty string value -> integer/out-of-range error" "$response" "$(expect_incr_error)"

send_cmd SET suffix_number 12abc > /dev/null
response=$(send_cmd INCR suffix_number)
check "INCR numeric prefix with suffix -> integer/out-of-range error" "$response" "$(expect_incr_error)"

response=$(send_cmd GET suffix_number)
check "Failed suffix INCR keeps original value" "$response" "$(expect_bulk 12abc)"

send_cmd SET decimal_number 3.14 > /dev/null
response=$(send_cmd INCR decimal_number)
check "INCR decimal string -> integer/out-of-range error" "$response" "$(expect_incr_error)"

send_cmd SET spaced_number " 5" > /dev/null
response=$(send_cmd INCR spaced_number)
check "INCR leading-space number -> integer/out-of-range error" "$response" "$(expect_incr_error)"

send_cmd SET double_minus --1 > /dev/null
response=$(send_cmd INCR double_minus)
check "INCR malformed negative value -> integer/out-of-range error" "$response" "$(expect_incr_error)"

# ---------------------------------------------------------------------------
# Test 6: Case-insensitive command names
# ---------------------------------------------------------------------------
send_cmd SET lower_case_counter 7 > /dev/null
response=$(send_cmd incr lower_case_counter)
check "incr lowercase command -> :8" "$response" "$(expect_int 8)"

send_cmd SET mixed_case_counter 8 > /dev/null
response=$(send_cmd InCr mixed_case_counter)
check "InCr mixed-case command -> :9" "$response" "$(expect_int 9)"

# ---------------------------------------------------------------------------
# Test 7: Expiry interactions
# ---------------------------------------------------------------------------
send_cmd SET expired_counter 9 PX 120 > /dev/null
sleep 0.2
response=$(send_cmd INCR expired_counter)
check "INCR expired key treats it as missing -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd GET expired_counter)
check "GET expired_counter after INCR -> 1" "$response" "$(expect_bulk 1)"

send_cmd SET ttl_counter 4 PX 250 > /dev/null
response=$(send_cmd INCR ttl_counter)
check "INCR key with TTL before expiry -> :5" "$response" "$(expect_int 5)"

sleep 0.35
response=$(send_cmd GET ttl_counter)
check "INCR preserves existing TTL, key expires later" "$response" "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 8: Sequential commands on one connection are handled in order
# ---------------------------------------------------------------------------
response=$(send_sequential_connection)
check "One connection SET, INCR, INCR, GET returns ordered responses" "$response" \
    "$(printf '+OK\r\n:11\r\n:12\r\n$2\r\n12\r')"

# ---------------------------------------------------------------------------
# Test 9: INCR does not unblock BLPOP clients waiting on another key
# ---------------------------------------------------------------------------
RESP_BLOCK_OTHER="$TMPDIR_LOCAL/incr_block_other"
start_blpop "$RESP_BLOCK_OTHER" incr_block_list 2
PID_BLOCK_OTHER=$BLPOP_PID

sleep 0.2
check_no_response "BLPOP is blocked before unrelated INCR" "$RESP_BLOCK_OTHER"

response=$(send_cmd INCR unrelated_counter)
check "INCR while BLPOP is blocked still responds immediately" "$response" "$(expect_int 1)"

sleep 0.2
check_no_response "Unrelated INCR does not wake blocked BLPOP" "$RESP_BLOCK_OTHER"

response=$(send_cmd RPUSH incr_block_list released)
check "RPUSH wakes BLPOP after unrelated INCR -> :1" "$response" "$(expect_int 1)"

if wait_for_response "$RESP_BLOCK_OTHER"; then
    response=$(cat "$RESP_BLOCK_OTHER")
    check "Blocked BLPOP receives pushed value after INCR noise" "$response" \
        "$(expect_array incr_block_list released)"
else
    fail "BLPOP did not receive value after RPUSH"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_client "$PID_BLOCK_OTHER"

# ---------------------------------------------------------------------------
# Test 10: INCR on the same missing key as a BLPOP waiter creates a string only
# ---------------------------------------------------------------------------
RESP_BLOCK_SAME="$TMPDIR_LOCAL/incr_block_same"
start_blpop "$RESP_BLOCK_SAME" incr_same_key_block 0.4
PID_BLOCK_SAME=$BLPOP_PID

sleep 0.1
response=$(send_cmd INCR incr_same_key_block)
check "INCR same missing key as BLPOP waiter -> :1" "$response" "$(expect_int 1)"

sleep 0.1
check_no_response "Same-key INCR does not satisfy blocked BLPOP" "$RESP_BLOCK_SAME"

if wait_for_response "$RESP_BLOCK_SAME" 10; then
    response=$(cat "$RESP_BLOCK_SAME")
    check "BLPOP waiter times out after same-key INCR creates string" "$response" \
        "$(expect_null_array)"
else
    fail "BLPOP waiter did not time out after same-key INCR"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_client "$PID_BLOCK_SAME"

response=$(send_cmd TYPE incr_same_key_block)
check "TYPE same-key INCR result -> +string" "$response" "$(expect_simple string)"

response=$(send_cmd GET incr_same_key_block)
check "GET same-key INCR result -> 1" "$response" "$(expect_bulk 1)"

# ---------------------------------------------------------------------------
# Test 11: Wrong arity and wrong type cases
# Keep these near the end because a broken implementation may close the server.
# ---------------------------------------------------------------------------
send_cmd SET arity_counter 1 > /dev/null
response=$(send_cmd INCR arity_counter extra)
check "INCR with an extra argument -> wrong number error" "$response" "$(expect_wrong_arity)"

send_cmd RPUSH incr_list_type a > /dev/null
response=$(send_cmd INCR incr_list_type)
check "INCR against list key -> WRONGTYPE error" "$response" "$(expect_wrongtype)"

response=$(send_cmd INCR)
check "INCR with no key -> wrong number error" "$response" "$(expect_wrong_arity)"

# ---------------------------------------------------------------------------
stop_server

rm -rf "$TMPDIR_LOCAL"

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "INCR command tests passed."
else
    exit 1
fi
