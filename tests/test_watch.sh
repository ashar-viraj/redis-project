#!/bin/bash
# Verify WATCH/UNWATCH optimistic locking, transaction cleanup, and blocking-adjacent cases

source "$(dirname "$0")/helpers.sh"

echo "=== Stage: WATCH/UNWATCH transactions ==="

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0
TMPDIR_LOCAL=$(mktemp -d)
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
    ) | timeout 12 nc -q 1 -W 8 127.0.0.1 6379 2>/dev/null
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

wait_for_file_glob() {
    local file="$1" pattern="$2" attempts="${3:-40}" i current
    for i in $(seq 1 "$attempts"); do
        current=$(cat "$file")
        if [[ "$current" == $pattern ]]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
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

check_watch_inside_multi_error() {
    local label="$1" response="$2" lower
    lower=$(printf '%s' "$response" | tr '[:upper:]' '[:lower:]')
    if [[ "$response" == -* ]] &&
       [[ "$lower" == *err* ]] &&
       [[ "$lower" == *watch* ]] &&
       [[ "$lower" == *"inside multi"* ]] &&
       [[ "$lower" == *"not allowed"* ]]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected error containing ERR, WATCH, inside MULTI, and not allowed"
        fail "  got      : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_multi_then_watch_error() {
    local label="$1" response="$2" first expected_prefix error_part
    printf -v expected_prefix '+OK\r\n'
    first="${response:0:${#expected_prefix}}"
    error_part="${response:${#expected_prefix}}"
    if [ "$first" = "$expected_prefix" ]; then
        check_watch_inside_multi_error "$label" "$error_part"
    else
        fail "$label"
        fail "  expected MULTI to return +OK before WATCH error"
        fail "  got      : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

expect_ok()          { printf '+OK\r'; }
expect_queued()      { printf '+QUEUED\r'; }
expect_pong()        { printf '+PONG\r'; }
expect_int()         { printf ':%d\r' "$1"; }
expect_bulk()        { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_null()        { printf '$-1\r'; }
expect_null_array()  { printf '*-1\r'; }

expect_array_ok() {
    local count="$1" i
    printf '*%d\r\n' "$count"
    for i in $(seq 1 "$count"); do
        if [ "$i" -eq "$count" ]; then
            printf '+OK\r'
        else
            printf '+OK\r\n'
        fi
    done
}

expect_array_bulk() {
    local count=$# i=1 word
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

expect_watch_multi_set_prefix() {
    printf '+OK\r\n+OK\r\n+QUEUED\r'
}

expect_watch_multi_two_queue_prefix() {
    printf '+OK\r\n+OK\r\n+QUEUED\r\n+QUEUED\r'
}

expect_exec_set_get_400() {
    printf '*2\r\n+OK\r\n$3\r\n400\r'
}

expect_blpop_exec_array() {
    local list_key="$1" value="$2"
    printf '*2\r\n'
    printf '*2\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n' "${#list_key}" "$list_key" "${#value}" "$value"
    printf '+OK\r'
}

# ---------------------------------------------------------------------------
# Test 1: WATCH parses simple, lower-case, and mixed-case commands
# ---------------------------------------------------------------------------
response=$(send_cmd WATCH watch_basic_key)
check "WATCH single key -> +OK" "$response" "$(expect_ok)"

response=$(send_cmd watch watch_lower_key)
check "watch lowercase -> +OK" "$response" "$(expect_ok)"

response=$(send_cmd WaTcH watch_mixed_key)
check "WaTcH mixed case -> +OK" "$response" "$(expect_ok)"

# ---------------------------------------------------------------------------
# Test 2: WATCH accepts several keys, including many keys in one command
# ---------------------------------------------------------------------------
response=$(send_cmd WATCH watch_multi_a watch_multi_b watch_multi_c)
check "WATCH multiple keys -> +OK" "$response" "$(expect_ok)"

response=$(send_cmd WATCH watch_many_1 watch_many_2 watch_many_3 watch_many_4 watch_many_5 watch_many_6 watch_many_7 watch_many_8 watch_many_9 watch_many_10)
check "WATCH ten keys in one command -> +OK" "$response" "$(expect_ok)"

# ---------------------------------------------------------------------------
# Test 3: WATCH can monitor missing keys without creating them
# ---------------------------------------------------------------------------
response=$(send_cmd WATCH watch_missing_parse)
check "WATCH missing key -> +OK" "$response" "$(expect_ok)"

response=$(send_cmd GET watch_missing_parse)
check "WATCH does not create a missing key" "$response" "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 4: WATCH inside MULTI returns the required error words
# ---------------------------------------------------------------------------
response=$(send_commands 1 MULTI 2 WATCH watch_inside_after_multi)
check_multi_then_watch_error "WATCH inside MULTI is rejected" "$response"

response=$(send_commands 1 MULTI 2 watch watch_inside_lower)
check_multi_then_watch_error "watch lowercase inside MULTI is rejected" "$response"

# ---------------------------------------------------------------------------
# Test 5: After rejected WATCH inside MULTI, the transaction still queues work
# ---------------------------------------------------------------------------
start_named_session WIQ
send_named_session_cmd WIQ MULTI
send_named_session_cmd WIQ WATCH watch_inside_still_tx
send_named_session_cmd WIQ SET watch_inside_still_tx value
send_named_session_cmd WIQ EXEC

printf -v EXPECTED_WIQ_PREFIX '+OK\r\n'
WIQ_PATTERN="${EXPECTED_WIQ_PREFIX}"'-*+QUEUED*'
if wait_for_file_glob "$WIQ_OUT" "$WIQ_PATTERN"; then
    pass "Rejected WATCH inside MULTI leaves connection in transaction mode"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    WIQ_RESPONSE=$(cat "$WIQ_OUT")
    fail "Rejected WATCH inside MULTI leaves connection in transaction mode"
    fail "  got      : $(printf '%s' "$WIQ_RESPONSE" | cat -A)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
close_named_session WIQ

# ---------------------------------------------------------------------------
# Test 6: Single watched key modified by another client aborts EXEC
# ---------------------------------------------------------------------------
send_cmd SET watch_abort_foo 100 > /dev/null
send_cmd SET watch_abort_bar 200 > /dev/null

start_named_session WA
send_named_session_cmd WA WATCH watch_abort_foo
send_named_session_cmd WA MULTI
send_named_session_cmd WA SET watch_abort_bar 300
check_file "Client A queues SET after WATCH" "$WA_OUT" "$(expect_watch_multi_set_prefix)"

response=$(send_cmd SET watch_abort_foo 200)
check "Client B modifies watched key -> +OK" "$response" "$(expect_ok)"

send_named_session_cmd WA EXEC
check_file "EXEC aborts with null array after watched key modification" \
    "$WA_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n*-1\r')"
close_named_session WA

response=$(send_cmd GET watch_abort_bar)
check "Aborted transaction did not change queued target key" "$response" "$(expect_bulk 200)"

# ---------------------------------------------------------------------------
# Test 7: Modifying an unwatched key does not abort the transaction
# ---------------------------------------------------------------------------
send_cmd SET watch_clean_baz 100 > /dev/null
send_cmd SET watch_clean_caz 200 > /dev/null

start_named_session WC
send_named_session_cmd WC WATCH watch_clean_baz
send_named_session_cmd WC MULTI
send_named_session_cmd WC SET watch_clean_caz 400
send_named_session_cmd WC GET watch_clean_caz
check_file "Clean WATCH transaction queues SET and GET" \
    "$WC_OUT" "$(expect_watch_multi_two_queue_prefix)"

response=$(send_cmd SET watch_clean_caz 300)
check "Client B modifies only an unwatched key -> +OK" "$response" "$(expect_ok)"

send_named_session_cmd WC EXEC
check_file "EXEC succeeds when watched key was untouched" \
    "$WC_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n+QUEUED\r\n%s' "$(expect_exec_set_get_400)")"
close_named_session WC

response=$(send_cmd GET watch_clean_caz)
check "Successful transaction overwrote the other client's unwatched write" \
    "$response" "$(expect_bulk 400)"

# ---------------------------------------------------------------------------
# Test 8: Setting a watched key back to the same value still counts as dirty
# ---------------------------------------------------------------------------
send_cmd SET watch_same_value original > /dev/null
send_cmd SET watch_same_target keep > /dev/null

start_named_session WSV
send_named_session_cmd WSV WATCH watch_same_value
send_named_session_cmd WSV MULTI
send_named_session_cmd WSV SET watch_same_target changed
check_file "Same-value dirty transaction queues SET" "$WSV_OUT" "$(expect_watch_multi_set_prefix)"

response=$(send_cmd SET watch_same_value original)
check "Client B touches watched key without changing final value" "$response" "$(expect_ok)"

send_named_session_cmd WSV EXEC
check_file "EXEC aborts even when watched key value is restored/same" \
    "$WSV_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n*-1\r')"
close_named_session WSV

response=$(send_cmd GET watch_same_target)
check "Same-value dirty abort preserved target key" "$response" "$(expect_bulk keep)"

# ---------------------------------------------------------------------------
# Test 9: Modification before MULTI still aborts later EXEC
# ---------------------------------------------------------------------------
send_cmd SET watch_before_multi_key 1 > /dev/null
send_cmd SET watch_before_multi_target stable > /dev/null

start_named_session WBM
send_named_session_cmd WBM WATCH watch_before_multi_key
check_file "WATCH before external modification -> +OK" "$WBM_OUT" "$(expect_ok)"

response=$(send_cmd INCR watch_before_multi_key)
check "Client B modifies watched key before MULTI" "$response" "$(expect_int 2)"

send_named_session_cmd WBM MULTI
send_named_session_cmd WBM SET watch_before_multi_target changed
send_named_session_cmd WBM EXEC
check_file "EXEC aborts when dirty happened before MULTI" \
    "$WBM_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n*-1\r')"
close_named_session WBM

response=$(send_cmd GET watch_before_multi_target)
check "Before-MULTI dirty abort preserved target" "$response" "$(expect_bulk stable)"

# ---------------------------------------------------------------------------
# Test 10: A queued write to the watched key itself succeeds if no one touched it
# ---------------------------------------------------------------------------
send_cmd SET watch_self_queue old > /dev/null

start_named_session WSQ
send_named_session_cmd WSQ WATCH watch_self_queue
send_named_session_cmd WSQ MULTI
send_named_session_cmd WSQ SET watch_self_queue new
send_named_session_cmd WSQ GET watch_self_queue
send_named_session_cmd WSQ EXEC
check_file "Queued write to watched key commits when watch stayed clean" \
    "$WSQ_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n+OK\r\n$3\r\nnew\r')"
close_named_session WSQ

response=$(send_cmd GET watch_self_queue)
check "Queued watched-key write persisted" "$response" "$(expect_bulk new)"

# ---------------------------------------------------------------------------
# Test 11: Multiple watched keys abort when any watched key is modified
# ---------------------------------------------------------------------------
send_cmd SET watch_multi_abort_foo 100 > /dev/null
send_cmd SET watch_multi_abort_bar 200 > /dev/null

start_named_session WMA
send_named_session_cmd WMA WATCH watch_multi_abort_foo watch_multi_abort_bar
send_named_session_cmd WMA MULTI
send_named_session_cmd WMA SET watch_multi_abort_bar 300
check_file "WATCH foo bar queues transaction" "$WMA_OUT" "$(expect_watch_multi_set_prefix)"

response=$(send_cmd SET watch_multi_abort_foo 200)
check "Client B modifies one of multiple watched keys" "$response" "$(expect_ok)"

send_named_session_cmd WMA EXEC
check_file "EXEC aborts when any watched key from a multi-key WATCH is dirty" \
    "$WMA_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n*-1\r')"
close_named_session WMA

response=$(send_cmd GET watch_multi_abort_bar)
check "Multi-key aborted transaction had no effect" "$response" "$(expect_bulk 200)"

# ---------------------------------------------------------------------------
# Test 12: Repeated WATCH calls accumulate watched keys
# ---------------------------------------------------------------------------
send_cmd SET watch_repeat_a A > /dev/null
send_cmd SET watch_repeat_b B > /dev/null
send_cmd SET watch_repeat_c C > /dev/null
send_cmd SET watch_repeat_target keep > /dev/null

start_named_session WREP
send_named_session_cmd WREP WATCH watch_repeat_a watch_repeat_b
send_named_session_cmd WREP WATCH watch_repeat_c
send_named_session_cmd WREP MULTI
send_named_session_cmd WREP SET watch_repeat_target changed
check_file "Repeated WATCH calls both return OK and queue transaction" \
    "$WREP_OUT" "$(printf '+OK\r\n+OK\r\n+OK\r\n+QUEUED\r')"

response=$(send_cmd SET watch_repeat_c changed)
check "Client B modifies key from second WATCH call" "$response" "$(expect_ok)"

send_named_session_cmd WREP EXEC
check_file "EXEC aborts from a key added by a later WATCH call" \
    "$WREP_OUT" "$(printf '+OK\r\n+OK\r\n+OK\r\n+QUEUED\r\n*-1\r')"
close_named_session WREP

response=$(send_cmd GET watch_repeat_target)
check "Repeated-WATCH abort preserved target" "$response" "$(expect_bulk keep)"

# ---------------------------------------------------------------------------
# Test 13: Large multi-key WATCH list aborts from a key in the middle
# ---------------------------------------------------------------------------
send_cmd SET watch_many_target stable > /dev/null

start_named_session WMANY
send_named_session_cmd WMANY WATCH watch_many_a watch_many_b watch_many_c watch_many_d watch_many_e watch_many_f watch_many_g watch_many_h watch_many_i watch_many_j watch_many_k watch_many_l
send_named_session_cmd WMANY MULTI
send_named_session_cmd WMANY SET watch_many_target changed
check_file "Large multi-key WATCH queues transaction" "$WMANY_OUT" "$(expect_watch_multi_set_prefix)"

response=$(send_cmd SET watch_many_g touched)
check "Client B modifies one key from a large WATCH list" "$response" "$(expect_ok)"

send_named_session_cmd WMANY EXEC
check_file "EXEC aborts for a dirty key in a large WATCH list" \
    "$WMANY_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n*-1\r')"
close_named_session WMANY

response=$(send_cmd GET watch_many_target)
check "Large-WATCH aborted transaction had no effect" "$response" "$(expect_bulk stable)"

# ---------------------------------------------------------------------------
# Test 14: Duplicate watched keys do not prevent dirty detection
# ---------------------------------------------------------------------------
send_cmd SET watch_duplicate_key one > /dev/null
send_cmd SET watch_duplicate_target keep > /dev/null

start_named_session WDUP
send_named_session_cmd WDUP WATCH watch_duplicate_key watch_duplicate_key watch_duplicate_key
send_named_session_cmd WDUP MULTI
send_named_session_cmd WDUP SET watch_duplicate_target changed
check_file "WATCH duplicate keys queues transaction" "$WDUP_OUT" "$(expect_watch_multi_set_prefix)"

response=$(send_cmd SET watch_duplicate_key two)
check "Client B modifies duplicated watched key" "$response" "$(expect_ok)"

send_named_session_cmd WDUP EXEC
check_file "EXEC aborts for duplicated watched key" \
    "$WDUP_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n*-1\r')"
close_named_session WDUP

response=$(send_cmd GET watch_duplicate_target)
check "Duplicate-key abort preserved target" "$response" "$(expect_bulk keep)"

# ---------------------------------------------------------------------------
# Test 15: Missing watched key created by another client aborts EXEC
# ---------------------------------------------------------------------------
send_cmd SET watch_missing_created_target keep > /dev/null

start_named_session WMC
send_named_session_cmd WMC WATCH watch_missing_created_key
check_file "WATCH non-existent key -> +OK" "$WMC_OUT" "$(expect_ok)"

response=$(send_cmd SET watch_missing_created_key 200)
check "Client B creates watched missing key" "$response" "$(expect_ok)"

send_named_session_cmd WMC MULTI
send_named_session_cmd WMC SET watch_missing_created_target changed
send_named_session_cmd WMC EXEC
check_file "EXEC aborts when a watched missing key is created" \
    "$WMC_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n*-1\r')"
close_named_session WMC

response=$(send_cmd GET watch_missing_created_target)
check "Missing-key creation abort preserved queued target" "$response" "$(expect_bulk keep)"

# ---------------------------------------------------------------------------
# Test 16: Multiple missing watched keys abort when any one is created
# ---------------------------------------------------------------------------
send_cmd SET watch_multi_missing_target keep > /dev/null

start_named_session WMM
send_named_session_cmd WMM WATCH watch_missing_a watch_missing_b watch_missing_c
send_named_session_cmd WMM MULTI
send_named_session_cmd WMM SET watch_multi_missing_target changed
check_file "WATCH multiple missing keys queues transaction" "$WMM_OUT" "$(expect_watch_multi_set_prefix)"

response=$(send_cmd SET watch_missing_b created)
check "Client B creates one of several missing watched keys" "$response" "$(expect_ok)"

send_named_session_cmd WMM EXEC
check_file "EXEC aborts when any missing watched key is created" \
    "$WMM_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n*-1\r')"
close_named_session WMM

response=$(send_cmd GET watch_multi_missing_target)
check "Multi-missing abort preserved target" "$response" "$(expect_bulk keep)"

# ---------------------------------------------------------------------------
# Test 17: A watched missing key can be created by the transaction if untouched
# ---------------------------------------------------------------------------
start_named_session WMS
send_named_session_cmd WMS WATCH watch_missing_self_create
send_named_session_cmd WMS MULTI
send_named_session_cmd WMS SET watch_missing_self_create made_by_exec
send_named_session_cmd WMS GET watch_missing_self_create
send_named_session_cmd WMS EXEC
check_file "Transaction can create its own watched missing key when no other client touched it" \
    "$WMS_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n+OK\r\n$12\r\nmade_by_exec\r')"
close_named_session WMS

response=$(send_cmd GET watch_missing_self_create)
check "Self-created watched missing key persisted" "$response" "$(expect_bulk made_by_exec)"

# ---------------------------------------------------------------------------
# Test 18: UNWATCH clears dirty watch state before a transaction
# ---------------------------------------------------------------------------
send_cmd SET unwatch_dirty_foo 100 > /dev/null

start_named_session UW
send_named_session_cmd UW WATCH unwatch_dirty_foo
check_file "WATCH before UNWATCH -> +OK" "$UW_OUT" "$(expect_ok)"

response=$(send_cmd SET unwatch_dirty_foo 200)
check "Client B dirties watched key before UNWATCH" "$response" "$(expect_ok)"

send_named_session_cmd UW UNWATCH
send_named_session_cmd UW MULTI
send_named_session_cmd UW SET unwatch_dirty_foo 400
send_named_session_cmd UW EXEC
check_file "UNWATCH clears dirty state so EXEC succeeds" \
    "$UW_OUT" "$(printf '+OK\r\n+OK\r\n+OK\r\n+QUEUED\r\n*1\r\n+OK\r')"
close_named_session UW

response=$(send_cmd GET unwatch_dirty_foo)
check "UNWATCH transaction write took effect" "$response" "$(expect_bulk 400)"

# ---------------------------------------------------------------------------
# Test 19: UNWATCH works with no prior WATCH
# ---------------------------------------------------------------------------
response=$(send_cmd UNWATCH)
check "UNWATCH without watched keys -> +OK" "$response" "$(expect_ok)"

response=$(send_cmd unwatch)
check "unwatch lowercase without watched keys -> +OK" "$response" "$(expect_ok)"

# ---------------------------------------------------------------------------
# Test 20: EXEC clears watch state after an aborted transaction
# ---------------------------------------------------------------------------
send_cmd SET exec_clear_foo 100 > /dev/null
send_cmd SET exec_clear_bar 200 > /dev/null

start_named_session ECA
send_named_session_cmd ECA WATCH exec_clear_foo
send_named_session_cmd ECA MULTI
send_named_session_cmd ECA SET exec_clear_bar 300
check_file "EXEC-clear first transaction queues SET" "$ECA_OUT" "$(expect_watch_multi_set_prefix)"

response=$(send_cmd SET exec_clear_foo 200)
check "Client B dirties key for EXEC-clear abort" "$response" "$(expect_ok)"

send_named_session_cmd ECA EXEC
send_named_session_cmd ECA MULTI
send_named_session_cmd ECA SET exec_clear_bar 300
send_named_session_cmd ECA EXEC
check_file "Second transaction succeeds because aborted EXEC cleared WATCH state" \
    "$ECA_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n*-1\r\n+OK\r\n+QUEUED\r\n*1\r\n+OK\r')"
close_named_session ECA

response=$(send_cmd GET exec_clear_bar)
check "Second transaction after aborted EXEC applied queued write" "$response" "$(expect_bulk 300)"

# ---------------------------------------------------------------------------
# Test 21: EXEC clears watch state after a successful transaction too
# ---------------------------------------------------------------------------
send_cmd SET exec_success_clear_watch watched > /dev/null
send_cmd SET exec_success_clear_target first > /dev/null

start_named_session ECS
send_named_session_cmd ECS WATCH exec_success_clear_watch
send_named_session_cmd ECS MULTI
send_named_session_cmd ECS SET exec_success_clear_target second
send_named_session_cmd ECS EXEC
check_file "Successful watched EXEC commits first transaction" \
    "$ECS_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n*1\r\n+OK\r')"

response=$(send_cmd SET exec_success_clear_watch dirtied_after_exec)
check "Client B modifies old watched key after successful EXEC" "$response" "$(expect_ok)"

send_named_session_cmd ECS MULTI
send_named_session_cmd ECS SET exec_success_clear_target third
send_named_session_cmd ECS EXEC
check_file "Second transaction succeeds because successful EXEC cleared WATCH state" \
    "$ECS_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n*1\r\n+OK\r\n+OK\r\n+QUEUED\r\n*1\r\n+OK\r')"
close_named_session ECS

response=$(send_cmd GET exec_success_clear_target)
check "Second transaction after successful EXEC applied queued write" "$response" "$(expect_bulk third)"

# ---------------------------------------------------------------------------
# Test 22: DISCARD clears dirty watch state and queued commands
# ---------------------------------------------------------------------------
send_cmd SET discard_clear_foo 100 > /dev/null
send_cmd SET discard_clear_bar 200 > /dev/null

start_named_session DCA
send_named_session_cmd DCA WATCH discard_clear_foo discard_clear_bar
send_named_session_cmd DCA MULTI
send_named_session_cmd DCA SET discard_clear_bar 300
check_file "DISCARD-clear transaction queues SET" "$DCA_OUT" "$(expect_watch_multi_set_prefix)"

response=$(send_cmd SET discard_clear_foo 400)
check "Client B dirties watched key before DISCARD" "$response" "$(expect_ok)"

send_named_session_cmd DCA DISCARD
send_named_session_cmd DCA MULTI
send_named_session_cmd DCA SET discard_clear_bar 300
send_named_session_cmd DCA EXEC
check_file "Transaction after DISCARD succeeds because WATCH state was cleared" \
    "$DCA_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n+OK\r\n+OK\r\n+QUEUED\r\n*1\r\n+OK\r')"
close_named_session DCA

response=$(send_cmd GET discard_clear_bar)
check "Transaction after DISCARD applied queued write" "$response" "$(expect_bulk 300)"

# ---------------------------------------------------------------------------
# Test 23: DISCARD clears clean watched keys and drops queued writes
# ---------------------------------------------------------------------------
send_cmd SET discard_clean_key watched > /dev/null
send_cmd SET discard_clean_target original > /dev/null

response=$(send_commands \
    2 WATCH discard_clean_key \
    1 MULTI \
    3 SET discard_clean_target discarded \
    1 DISCARD \
    2 GET discard_clean_target)
check "DISCARD drops queued write from a clean watched transaction" \
    "$response" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n+OK\r\n$8\r\noriginal\r')"

response=$(send_cmd GET discard_clean_target)
check "Discarded clean watched transaction left original value" "$response" "$(expect_bulk original)"

# ---------------------------------------------------------------------------
# Test 24: Dirty WATCH aborts before a queued BLPOP can block
# ---------------------------------------------------------------------------
send_cmd SET watch_block_dirty_key clean > /dev/null

start_named_session WBD
send_named_session_cmd WBD WATCH watch_block_dirty_key
send_named_session_cmd WBD MULTI
send_named_session_cmd WBD BLPOP watch_block_empty_list 0
send_named_session_cmd WBD SET watch_block_after should_not_run
check_file "Dirty blocking transaction queues BLPOP and SET" \
    "$WBD_OUT" "$(expect_watch_multi_two_queue_prefix)"

response=$(send_cmd SET watch_block_dirty_key dirty)
check "Client B dirties watched key before EXEC with queued BLPOP" "$response" "$(expect_ok)"

send_named_session_cmd WBD EXEC
check_file "EXEC aborts immediately instead of blocking on queued BLPOP" \
    "$WBD_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n+QUEUED\r\n*-1\r')" 25
close_named_session WBD

response=$(send_cmd GET watch_block_after)
check "Aborted blocking transaction did not execute later SET" "$response" "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 25: Clean WATCH with a ready BLPOP returns nested array inside EXEC
# ---------------------------------------------------------------------------
send_cmd SET watch_block_clean_guard untouched > /dev/null
send_cmd RPUSH watch_block_ready_list ready_value extra_value > /dev/null

start_named_session WBC
send_named_session_cmd WBC WATCH watch_block_clean_guard
send_named_session_cmd WBC MULTI
send_named_session_cmd WBC BLPOP watch_block_ready_list 0
send_named_session_cmd WBC SET watch_block_ready_marker done
send_named_session_cmd WBC EXEC
check_file "Clean watched transaction can execute a ready BLPOP inside EXEC" \
    "$WBC_OUT" "$(printf '+OK\r\n+OK\r\n+QUEUED\r\n+QUEUED\r\n%s' "$(expect_blpop_exec_array watch_block_ready_list ready_value)")" 60
close_named_session WBC

response=$(send_cmd GET watch_block_ready_marker)
check "Command after ready BLPOP in watched transaction executed" "$response" "$(expect_bulk done)"

response=$(send_cmd LPOP watch_block_ready_list)
check "Ready BLPOP consumed only the first pushed value" "$response" "$(expect_bulk extra_value)"

# ---------------------------------------------------------------------------
# Test 26: UNWATCH after dirtying lets a later blocking command execute normally
# ---------------------------------------------------------------------------
send_cmd SET unwatch_block_dirty_key clean > /dev/null
send_cmd RPUSH unwatch_block_ready_list released > /dev/null

start_named_session UWB
send_named_session_cmd UWB WATCH unwatch_block_dirty_key
check_file "WATCH before UNWATCH blocking flow -> +OK" "$UWB_OUT" "$(expect_ok)"

response=$(send_cmd SET unwatch_block_dirty_key dirty)
check "Client B dirties key before UNWATCH blocking flow" "$response" "$(expect_ok)"

send_named_session_cmd UWB UNWATCH
send_named_session_cmd UWB MULTI
send_named_session_cmd UWB BLPOP unwatch_block_ready_list 0
send_named_session_cmd UWB SET unwatch_block_marker done
send_named_session_cmd UWB EXEC
check_file "UNWATCH permits later ready BLPOP transaction to execute" \
    "$UWB_OUT" "$(printf '+OK\r\n+OK\r\n+OK\r\n+QUEUED\r\n+QUEUED\r\n%s' "$(expect_blpop_exec_array unwatch_block_ready_list released)")" 60
close_named_session UWB

response=$(send_cmd GET unwatch_block_marker)
check "UNWATCH blocking transaction ran later SET" "$response" "$(expect_bulk done)"

# ---------------------------------------------------------------------------
# Test 27: Invalid and empty WATCH/UNWATCH-adjacent inputs do not crash server
# ---------------------------------------------------------------------------
response=$(send_cmd WATCH)
check_error "WATCH with no keys returns an error" "$response"

response=$(send_cmd UNWATCH extra_arg)
check_error_or_ok "UNWATCH with an extra argument is rejected or ignored without crashing" "$response"

response=$(send_cmd "")
check_error "Empty command name returns an error" "$response"

response=$(send_raw_bytes '*0\r\n')
check_error_or_no_response "Empty RESP array is rejected or ignored without crashing" "$response"

response=$(send_raw_bytes '*2\r\n$5\r\nWATCH\r\n')
check_error_or_no_response "Truncated WATCH command is rejected or ignored without crashing" "$response"

response=$(send_cmd PING)
check "Server still responds after invalid WATCH/UNWATCH inputs" "$response" "$(expect_pong)"

# ---------------------------------------------------------------------------
cleanup
trap - EXIT

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "WATCH/UNWATCH transaction tests passed."
else
    exit 1
fi
