#!/bin/bash
# Verify MULTI/EXEC transactions, command queueing, empty transactions, and blocking-adjacent cases

source "$(dirname "$0")/helpers.sh"

echo "=== Stage: MULTI/EXEC transactions ==="

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0
TMPDIR_LOCAL=$(mktemp -d)
SESSION_PID=""
SESSION_FD=""
SESSION_IN=""
SESSION_OUT=""
EXTRA_SESSION_PREFIXES=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

write_resp_command() {
    local payload part word
    printf -v payload '*%d\r\n' "$#"
    for word in "$@"; do
        printf -v part '$%d\r\n%s\r\n' "${#word}" "$word"
        payload+="$part"
    done
    printf '%s' "$payload"
}

send_cmd() {
    local tmp
    tmp=$(mktemp)
    write_resp_command "$@" > "$tmp"
    timeout 4 nc -q 1 -W 2 127.0.0.1 6379 < "$tmp" 2>/dev/null
    rm -f "$tmp"
}

send_raw_bytes() {
    local tmp
    tmp=$(mktemp)
    printf '%b' "$1" > "$tmp"
    timeout 4 nc -q 1 -W 2 127.0.0.1 6379 < "$tmp" 2>/dev/null
    rm -f "$tmp"
}

send_commands() {
    (
        local argc i
        while [ "$#" -gt 0 ]; do
            argc="$1"
            shift
            local words=()
            for i in $(seq 1 "$argc"); do
                words+=("$1")
                shift
            done
            write_resp_command "${words[@]}"
            sleep 0.08
        done
    ) | timeout 10 nc -q 1 -W 6 127.0.0.1 6379 2>/dev/null
}

start_session() {
    local name="$1"
    SESSION_IN="$TMPDIR_LOCAL/${name}.in"
    SESSION_OUT="$TMPDIR_LOCAL/${name}.out"
    mkfifo "$SESSION_IN"
    : > "$SESSION_OUT"
    nc 127.0.0.1 6379 < "$SESSION_IN" > "$SESSION_OUT" 2>/dev/null &
    SESSION_PID=$!
    exec {SESSION_FD}>"$SESSION_IN"
}

send_session_cmd() {
    write_resp_command "$@" >&${SESSION_FD}
    sleep 0.08
}

close_session() {
    if [ -n "${SESSION_PID:-}" ]; then
        if kill -0 "$SESSION_PID" 2>/dev/null; then
            kill "$SESSION_PID" 2>/dev/null
            sleep 0.1
        fi
        if kill -0 "$SESSION_PID" 2>/dev/null; then
            kill -9 "$SESSION_PID" 2>/dev/null
        fi
        SESSION_PID=""
    fi
    if [ -n "${SESSION_FD:-}" ]; then
        exec {SESSION_FD}>&-
        SESSION_FD=""
    fi
}

start_named_session() {
    local prefix="$1" in_file out_file pid fd
    in_file="$TMPDIR_LOCAL/${prefix}.in"
    out_file="$TMPDIR_LOCAL/${prefix}.out"
    mkfifo "$in_file"
    : > "$out_file"
    nc 127.0.0.1 6379 < "$in_file" > "$out_file" 2>/dev/null &
    pid=$!
    exec {fd}>"$in_file"
    eval "${prefix}_IN=\"\$in_file\""
    eval "${prefix}_OUT=\"\$out_file\""
    eval "${prefix}_PID=\"\$pid\""
    eval "${prefix}_FD=\"\$fd\""
    EXTRA_SESSION_PREFIXES+=("$prefix")
}

send_named_session_cmd() {
    local prefix="$1" fd_var fd
    shift
    fd_var="${prefix}_FD"
    fd="${!fd_var}"
    write_resp_command "$@" >&${fd}
    sleep 0.08
}

close_named_session() {
    local prefix="$1" pid_var fd_var pid fd
    pid_var="${prefix}_PID"
    fd_var="${prefix}_FD"
    pid="${!pid_var:-}"
    fd="${!fd_var:-}"

    if [ -n "$pid" ]; then
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            sleep 0.1
        fi
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null
        fi
        eval "${pid_var}=''"
    fi
    if [ -n "$fd" ]; then
        eval "exec ${fd}>&-"
        eval "${fd_var}=''"
    fi
}

cleanup() {
    local prefix
    for prefix in "${EXTRA_SESSION_PREFIXES[@]}"; do
        close_named_session "$prefix"
    done
    close_session
    rm -rf "$TMPDIR_LOCAL"
    stop_server
}

trap cleanup EXIT

wait_for_file_response() {
    local file="$1" expected="$2" attempts="${3:-40}" i current
    for i in $(seq 1 "$attempts"); do
        current=$(cat "$file")
        if [ "$current" = "$expected" ]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

check() {
    local label="$1" response="$2" expected="$3"
    if [ "$response" = "$expected" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected : $(printf '%s' "$expected" | cat -A)"
        fail "  got      : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_file() {
    local label="$1" file="$2" expected="$3" attempts="${4:-40}" response
    if wait_for_file_response "$file" "$expected" "$attempts"; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        response=$(cat "$file")
        fail "$label"
        fail "  expected : $(printf '%s' "$expected" | cat -A)"
        fail "  got      : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_error() {
    local label="$1" response="$2"
    if [[ "$response" == -* ]]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected an error response beginning with '-'"
        fail "  got      : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_error_or_no_response() {
    local label="$1" response="$2"
    if [ -z "$response" ] || [[ "$response" == -* ]]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected an error response or no response"
        fail "  got      : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_error_or_ok() {
    local label="$1" response="$2"
    if [[ "$response" == -* ]] || [ "$response" = "$(expect_ok)" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected an error response or +OK"
        fail "  got      : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

expect_ok()                 { printf '+OK\r'; }
expect_pong()               { printf '+PONG\r'; }
expect_queued()             { printf '+QUEUED\r'; }
expect_int()                { printf ':%d\r' "$1"; }
expect_bulk()               { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_null()               { printf '$-1\r'; }
expect_empty_array()        { printf '*0\r'; }
expect_exec_without_multi() { printf -- '-ERR EXEC without MULTI\r'; }
expect_discard_without_multi() { printf -- '-ERR DISCARD without MULTI\r'; }

expect_ok_then_queued() {
    local queued="$1" i
    if [ "$queued" -eq 0 ]; then
        printf '+OK\r'
        return
    fi

    printf '+OK\r\n'
    for i in $(seq 1 "$queued"); do
        if [ "$i" -eq "$queued" ]; then
            printf '+QUEUED\r'
        else
            printf '+QUEUED\r\n'
        fi
    done
}

expect_exec_set_incr_bar_getbar() {
    printf '+OK\r\n'
    printf '+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n'
    printf '*4\r\n+OK\r\n:7\r\n:1\r\n$1\r\n1\r'
}

expect_empty_value_transaction() {
    printf '+OK\r\n+QUEUED\r\n+QUEUED\r\n'
    printf '*2\r\n+OK\r\n$0\r\n\r'
}

expect_large_counter_transaction() {
    local i
    printf '+OK\r\n'
    for i in $(seq 1 17); do
        printf '+QUEUED\r\n'
    done
    printf '*17\r\n+OK\r\n'
    for i in $(seq 1 15); do
        printf ':%d\r\n' "$i"
    done
    printf '$2\r\n15\r'
}

expect_blpop_ready_transaction() {
    printf '+OK\r\n+QUEUED\r\n+QUEUED\r\n'
    printf '*2\r\n*2\r\n$14\r\ntx_blpop_ready\r\n$5\r\nfirst\r\n+OK\r'
}

expect_blpop_wait_prefix() {
    printf '+OK\r\n+QUEUED\r\n+QUEUED\r'
}

expect_blpop_wait_full() {
    printf '+OK\r\n+QUEUED\r\n+QUEUED\r\n'
    printf '*2\r\n*2\r\n$13\r\ntx_block_wait\r\n$8\r\nreleased\r\n$-1\r'
}

expect_discard_basic_flow() {
    printf '+OK\r\n+QUEUED\r\n+QUEUED\r\n+OK\r\n$-1\r\n'
    printf -- '-ERR DISCARD without MULTI\r'
}

expect_discard_existing_value_flow() {
    printf '+OK\r\n+OK\r\n+QUEUED\r\n+OK\r\n$5\r\nalive\r'
}

expect_failure_transaction() {
    printf '+OK\r\n+OK\r\n+OK\r\n+QUEUED\r\n+QUEUED\r\n'
    printf '*2\r\n-ERR value is not an integer or out of range\r\n:42\r'
}

expect_failure_continues_transaction() {
    printf '+OK\r\n+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n'
    printf '*3\r\n-ERR value is not an integer or out of range\r\n+OK\r\n$2\r\nok\r'
}

expect_concurrent_a_before_exec() {
    printf '+OK\r\n+QUEUED\r\n+QUEUED\r'
}

expect_concurrent_b_before_exec() {
    printf '+OK\r\n+QUEUED\r\n+QUEUED\r'
}

expect_concurrent_a_after_exec() {
    printf '+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n+OK\r\n:42\r'
}

expect_concurrent_b_after_exec() {
    printf '+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n:43\r\n$2\r\n43\r'
}

expect_discard_concurrent_a_after_discard() {
    printf '+OK\r\n+QUEUED\r\n+OK\r'
}

expect_discard_concurrent_b_after_exec() {
    printf '+OK\r\n+QUEUED\r\n*1\r\n:1\r'
}

# ---------------------------------------------------------------------------
# Test 1: MULTI returns OK and is case-insensitive
# ---------------------------------------------------------------------------
response=$(send_cmd MULTI)
check "MULTI -> +OK" "$response" "$(expect_ok)"

response=$(send_cmd multi)
check "multi lowercase -> +OK" "$response" "$(expect_ok)"

response=$(send_cmd MuLtI)
check "MuLtI mixed case -> +OK" "$response" "$(expect_ok)"

# ---------------------------------------------------------------------------
# Test 2: EXEC without MULTI returns the exact required error
# ---------------------------------------------------------------------------
response=$(send_cmd EXEC)
check "EXEC without MULTI -> ERR EXEC without MULTI" "$response" \
    "$(expect_exec_without_multi)"

response=$(send_cmd exec)
check "exec lowercase without MULTI -> ERR EXEC without MULTI" "$response" \
    "$(expect_exec_without_multi)"

# ---------------------------------------------------------------------------
# Test 3: Empty transaction returns an empty array and leaves transaction mode
# ---------------------------------------------------------------------------
response=$(send_commands 1 MULTI 1 EXEC)
check "MULTI followed immediately by EXEC -> empty array" "$response" \
    "$(printf '+OK\r\n*0\r')"

response=$(send_commands 1 MULTI 1 EXEC 1 EXEC)
check "EXEC after empty transaction reset -> ERR EXEC without MULTI" "$response" \
    "$(printf '+OK\r\n*0\r\n-ERR EXEC without MULTI\r')"

# ---------------------------------------------------------------------------
# Test 4: Commands are queued and not executed if the connection closes before EXEC
# ---------------------------------------------------------------------------
response=$(send_commands 1 MULTI 3 SET tx_closed 99 2 INCR tx_closed)
check "Queued SET/INCR without EXEC return QUEUED only" "$response" \
    "$(expect_ok_then_queued 2)"

response=$(send_cmd GET tx_closed)
check "Closing a transaction connection before EXEC does not write queued SET" \
    "$response" "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 5: Queued writes are invisible to other connections until EXEC
# ---------------------------------------------------------------------------
start_session "tx_visibility"
send_session_cmd MULTI
send_session_cmd SET tx_foo 6
send_session_cmd INCR tx_foo
send_session_cmd INCR tx_bar
send_session_cmd GET tx_bar

check_file "Same transaction connection gets QUEUED for four commands" \
    "$SESSION_OUT" "$(expect_ok_then_queued 4)"

response=$(send_cmd GET tx_foo)
check "Another connection cannot see tx_foo before EXEC" "$response" \
    "$(expect_null)"

response=$(send_cmd GET tx_bar)
check "Another connection cannot see tx_bar before EXEC" "$response" \
    "$(expect_null)"

send_session_cmd EXEC
check_file "EXEC returns array of SET/INCR/INCR/GET responses" \
    "$SESSION_OUT" "$(expect_exec_set_incr_bar_getbar)"
close_session

response=$(send_cmd GET tx_foo)
check "tx_foo exists after EXEC with value 7" "$response" "$(expect_bulk 7)"

response=$(send_cmd GET tx_bar)
check "tx_bar exists after EXEC with value 1" "$response" "$(expect_bulk 1)"

# ---------------------------------------------------------------------------
# Test 6: Transaction state is per connection
# ---------------------------------------------------------------------------
start_session "tx_per_connection"
send_session_cmd MULTI
send_session_cmd SET tx_conn_only yes

check_file "Connection A is in MULTI and queues its SET" \
    "$SESSION_OUT" "$(expect_ok_then_queued 1)"

response=$(send_cmd EXEC)
check "Connection B EXEC is still outside MULTI" "$response" \
    "$(expect_exec_without_multi)"

response=$(send_cmd GET tx_conn_only)
check "Connection B cannot see Connection A queued SET" "$response" \
    "$(expect_null)"

send_session_cmd EXEC
check_file "Connection A EXEC commits its queued SET" "$SESSION_OUT" \
    "$(printf '+OK\r\n+QUEUED\r\n*1\r\n+OK\r')"
close_session

response=$(send_cmd GET tx_conn_only)
check "Connection B sees Connection A value after EXEC" "$response" \
    "$(expect_bulk yes)"

# ---------------------------------------------------------------------------
# Test 7: Empty string values work correctly inside transactions
# ---------------------------------------------------------------------------
response=$(send_commands 1 MULTI 3 SET tx_empty_value "" 2 GET tx_empty_value 1 EXEC)
check "Transaction can SET and GET an empty bulk string value" "$response" \
    "$(expect_empty_value_transaction)"

response=$(send_cmd GET tx_empty_value)
check "Empty value persisted after EXEC" "$response" "$(printf '$0\r\n\r')"

# ---------------------------------------------------------------------------
# Test 8: Larger transaction with many queued operations
# ---------------------------------------------------------------------------
start_session "tx_large"
send_session_cmd MULTI
send_session_cmd SET tx_big_counter 0
for _ in $(seq 1 15); do
    send_session_cmd INCR tx_big_counter
done
send_session_cmd GET tx_big_counter
send_session_cmd EXEC

check_file "Large transaction returns every queued command response in order" \
    "$SESSION_OUT" "$(expect_large_counter_transaction)" 80
close_session

response=$(send_cmd GET tx_big_counter)
check "Large transaction final value persisted" "$response" "$(expect_bulk 15)"

# ---------------------------------------------------------------------------
# Test 9: Blocking commands are queued and do not block before EXEC
# ---------------------------------------------------------------------------
response=$(send_commands 1 MULTI 3 BLPOP tx_no_exec_block 2 3 SET tx_no_exec_after ok)
check "BLPOP inside MULTI is queued and does not block before EXEC" "$response" \
    "$(expect_ok_then_queued 2)"

response=$(send_cmd GET tx_no_exec_after)
check "Command after queued BLPOP was not executed without EXEC" "$response" \
    "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 10: EXEC can return a nested array response from a queued BLPOP
# ---------------------------------------------------------------------------
send_cmd RPUSH tx_blpop_ready first second > /dev/null

response=$(send_commands \
    1 MULTI \
    3 BLPOP tx_blpop_ready 0 \
    3 SET tx_blpop_marker done \
    1 EXEC)
check "Queued BLPOP on a ready list returns nested array inside EXEC" "$response" \
    "$(expect_blpop_ready_transaction)"

response=$(send_cmd LPOP tx_blpop_ready)
check "BLPOP inside EXEC consumed only the first list element" "$response" \
    "$(expect_bulk second)"

response=$(send_cmd GET tx_blpop_marker)
check "Command after BLPOP inside EXEC also executed" "$response" \
    "$(expect_bulk done)"

# ---------------------------------------------------------------------------
# Test 11: Queued BLPOP waits for EXEC, not for data pushed while queued
# ---------------------------------------------------------------------------
start_session "tx_blpop_wait"
send_session_cmd MULTI
send_session_cmd BLPOP tx_block_wait 0
send_session_cmd GET tx_after_missing

check_file "Queued BLPOP on an empty list returns QUEUED immediately" \
    "$SESSION_OUT" "$(expect_blpop_wait_prefix)"

response=$(send_cmd RPUSH tx_block_wait released)
check "RPUSH while BLPOP is queued stores the value for later EXEC" "$response" \
    "$(expect_int 1)"

send_session_cmd EXEC
check_file "EXEC later consumes the value pushed while BLPOP was queued" \
    "$SESSION_OUT" "$(expect_blpop_wait_full)" 60
close_session

response=$(send_cmd LPOP tx_block_wait)
check "Queued BLPOP consumed the pushed value during EXEC" "$response" \
    "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 12: DISCARD without MULTI returns the exact required error
# ---------------------------------------------------------------------------
response=$(send_cmd DISCARD)
check "DISCARD without MULTI -> ERR DISCARD without MULTI" "$response" \
    "$(expect_discard_without_multi)"

response=$(send_cmd discard)
check "discard lowercase without MULTI -> ERR DISCARD without MULTI" "$response" \
    "$(expect_discard_without_multi)"

# ---------------------------------------------------------------------------
# Test 13: DISCARD clears queued commands and exits transaction mode
# ---------------------------------------------------------------------------
response=$(send_commands \
    1 MULTI \
    3 SET tx_discard_foo 41 \
    2 INCR tx_discard_foo \
    1 DISCARD \
    2 GET tx_discard_foo \
    1 DISCARD)
check "DISCARD aborts queued SET/INCR and second DISCARD errors" "$response" \
    "$(expect_discard_basic_flow)"

response=$(send_cmd GET tx_discard_foo)
check "Discarded transaction leaves tx_discard_foo missing" "$response" \
    "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 14: DISCARD does not remove existing values; it only drops queued work
# ---------------------------------------------------------------------------
response=$(send_commands \
    3 SET tx_discard_keep alive \
    1 MULTI \
    3 SET tx_discard_keep dead \
    1 DISCARD \
    2 GET tx_discard_keep)
check "DISCARD keeps pre-transaction value intact" "$response" \
    "$(expect_discard_existing_value_flow)"

response=$(send_commands 1 MULTI 1 DISCARD 1 EXEC)
check "EXEC after DISCARD is outside MULTI" "$response" \
    "$(printf '+OK\r\n+OK\r\n-ERR EXEC without MULTI\r')"

# ---------------------------------------------------------------------------
# Test 15: Runtime command failures are returned inside EXEC arrays
# ---------------------------------------------------------------------------
response=$(send_commands \
    3 SET tx_fail_foo abc \
    3 SET tx_fail_bar 41 \
    1 MULTI \
    2 INCR tx_fail_foo \
    2 INCR tx_fail_bar \
    1 EXEC)
check "EXEC returns INCR error plus successful INCR result" "$response" \
    "$(expect_failure_transaction)"

response=$(send_cmd GET tx_fail_foo)
check "Failed INCR inside EXEC keeps original string value" "$response" \
    "$(expect_bulk abc)"

response=$(send_cmd GET tx_fail_bar)
check "Successful INCR after transaction error persists" "$response" \
    "$(expect_bulk 42)"

response=$(send_commands \
    3 SET tx_fail_continues nope \
    1 MULTI \
    2 INCR tx_fail_continues \
    3 SET tx_fail_after ok \
    2 GET tx_fail_after \
    1 EXEC)
check "Commands after a failed queued command still execute" "$response" \
    "$(expect_failure_continues_transaction)"

response=$(send_cmd GET tx_fail_after)
check "SET after failed INCR in same EXEC persisted" "$response" \
    "$(expect_bulk ok)"

# ---------------------------------------------------------------------------
# Test 16: Multiple concurrent transactions keep separate queues
# ---------------------------------------------------------------------------
send_cmd SET tx_multi_shared 40 > /dev/null

start_named_session TXA
send_named_session_cmd TXA MULTI
send_named_session_cmd TXA SET tx_multi_shared 41
send_named_session_cmd TXA INCR tx_multi_shared

start_named_session TXB
send_named_session_cmd TXB MULTI
send_named_session_cmd TXB INCR tx_multi_shared
send_named_session_cmd TXB GET tx_multi_shared

check_file "Transaction A queues SET+INCR on its own connection" \
    "$TXA_OUT" "$(expect_concurrent_a_before_exec)"
check_file "Transaction B queues INCR+GET on its own connection" \
    "$TXB_OUT" "$(expect_concurrent_b_before_exec)"

response=$(send_cmd GET tx_multi_shared)
check "Concurrent queued transactions are invisible before EXEC" "$response" \
    "$(expect_bulk 40)"

send_named_session_cmd TXA EXEC
check_file "Transaction A EXEC commits SET then INCR to 42" \
    "$TXA_OUT" "$(expect_concurrent_a_after_exec)"

response=$(send_cmd GET tx_multi_shared)
check "Shared key is 42 after transaction A EXEC" "$response" \
    "$(expect_bulk 42)"

send_named_session_cmd TXB EXEC
check_file "Transaction B EXEC sees transaction A result and increments to 43" \
    "$TXB_OUT" "$(expect_concurrent_b_after_exec)"

close_named_session TXA
close_named_session TXB

response=$(send_cmd GET tx_multi_shared)
check "Shared key is 43 after both concurrent transactions EXEC" "$response" \
    "$(expect_bulk 43)"

# ---------------------------------------------------------------------------
# Test 17: DISCARD on one open transaction does not affect another client
# ---------------------------------------------------------------------------
start_named_session TXD1
send_named_session_cmd TXD1 MULTI
send_named_session_cmd TXD1 SET tx_multi_discard 10

start_named_session TXD2
send_named_session_cmd TXD2 MULTI
send_named_session_cmd TXD2 INCR tx_multi_discard

send_named_session_cmd TXD1 DISCARD
check_file "Transaction D1 DISCARD drops only its own queue" \
    "$TXD1_OUT" "$(expect_discard_concurrent_a_after_discard)"

response=$(send_cmd GET tx_multi_discard)
check "D1 discarded SET is not visible before D2 EXEC" "$response" \
    "$(expect_null)"

send_named_session_cmd TXD2 EXEC
check_file "Transaction D2 queue survives D1 DISCARD and executes" \
    "$TXD2_OUT" "$(expect_discard_concurrent_b_after_exec)"

close_named_session TXD1
close_named_session TXD2

response=$(send_cmd GET tx_multi_discard)
check "D2 EXEC created tx_multi_discard after D1 discarded its SET" "$response" \
    "$(expect_bulk 1)"

# ---------------------------------------------------------------------------
# Test 18: Invalid and empty inputs
# ---------------------------------------------------------------------------
response=$(send_cmd MULTI extra)
check_error_or_ok "MULTI with an extra argument is handled without crashing" \
    "$response"

response=$(send_cmd EXEC extra)
check_error "EXEC with an extra argument returns an error" "$response"

response=$(send_cmd "")
check_error "Empty command name returns an error" "$response"

response=$(send_raw_bytes '*0\r\n')
check_error_or_no_response "Empty RESP array is rejected or ignored without crashing" \
    "$response"

response=$(send_cmd PING)
check "Server still responds after invalid/empty transaction-adjacent inputs" \
    "$response" "$(expect_pong)"

# ---------------------------------------------------------------------------
cleanup
trap - EXIT

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "MULTI/EXEC transaction tests passed."
else
    exit 1
fi
