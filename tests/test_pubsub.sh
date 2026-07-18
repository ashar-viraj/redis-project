#!/bin/bash
# Verify Redis pub/sub support: SUBSCRIBE, subscribed mode, PING, PUBLISH,
# delivery, and UNSUBSCRIBE across multiple long-lived clients.

source "$(dirname "$0")/helpers.sh"

echo "=== Stage: Pub/Sub commands ==="

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0
TMPDIR_LOCAL=$(mktemp -d)

declare -a SUB_NAMES=()
declare -a SUB_FIFOS=()
declare -a SUB_OUTS=()
declare -a SUB_PIDS=()
declare -a SUB_FDS=()
NEW_CLIENT_ID=""
LAST_RESPONSE=""

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

start_pubsub_client() {
    local name="$1"
    local idx="${#SUB_PIDS[@]}"
    local fifo="$TMPDIR_LOCAL/${name}.fifo"
    local out="$TMPDIR_LOCAL/${name}.out"
    local fd

    mkfifo "$fifo"
    : > "$out"
    timeout 120 nc 127.0.0.1 6379 < "$fifo" > "$out" 2>/dev/null &
    local pid=$!
    sleep 0.05
    exec {fd}<>"$fifo"

    SUB_NAMES[$idx]="$name"
    SUB_FIFOS[$idx]="$fifo"
    SUB_OUTS[$idx]="$out"
    SUB_PIDS[$idx]="$pid"
    SUB_FDS[$idx]="$fd"
    NEW_CLIENT_ID="$idx"
}

send_client() {
    local idx="$1"
    shift
    local fd="${SUB_FDS[$idx]}"
    write_resp_command "$@" >&"$fd"
}

cleanup_pubsub_clients() {
    local fd pid
    for fd in "${SUB_FDS[@]}"; do
        if [ -n "$fd" ]; then
            eval "exec ${fd}>&-" 2>/dev/null || true
        fi
    done
    for pid in "${SUB_PIDS[@]}"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
    done
    sleep 0.1
    for pid in "${SUB_PIDS[@]}"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
        if [ -n "$pid" ]; then
            wait "$pid" 2>/dev/null || true
        fi
    done
}

stop_server_bounded() {
    [ "${EXTERNAL_SERVER:-0}" = "1" ] && return

    if [ -n "${TAIL_PID:-}" ]; then
        kill "$TAIL_PID" 2>/dev/null || true
        wait "$TAIL_PID" 2>/dev/null || true
        TAIL_PID=""
    fi

    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            kill -KILL "$SERVER_PID" 2>/dev/null || true
        fi
        wait "$SERVER_PID" 2>/dev/null || true
    fi

    fuser -k 6379/tcp > /dev/null 2>&1 || true
    SERVER_PID=""
}

cleanup_pubsub_script() {
    cleanup_pubsub_clients
    rm -rf "$TMPDIR_LOCAL"
    stop_server_bounded
}
trap cleanup_pubsub_script EXIT

file_size() {
    wc -c < "$1" | tr -d '[:space:]'
}

read_since() {
    local file="$1"
    local offset="$2"
    tail -c +"$((offset + 1))" "$file" 2>/dev/null
}

wait_for_expected_since() {
    local file="$1"
    local offset="$2"
    local expected="$3"
    local attempts="${4:-40}"
    local i data

    for i in $(seq 1 "$attempts"); do
        data=$(read_since "$file" "$offset")
        if [ "$data" = "$expected" ]; then
            LAST_RESPONSE="$data"
            return 0
        fi
        sleep 0.1
    done

    LAST_RESPONSE=$(read_since "$file" "$offset")
    return 1
}

wait_for_subscribed_mode_error_since() {
    local file="$1"
    local offset="$2"
    local command="$3"
    local attempts="${4:-30}"
    local cmd_lower data lowered i
    cmd_lower=$(printf '%s' "$command" | tr '[:upper:]' '[:lower:]')

    for i in $(seq 1 "$attempts"); do
        data=$(read_since "$file" "$offset")
        lowered=$(printf '%s' "$data" | tr '[:upper:]' '[:lower:]')
        if [[ "$lowered" == -*err*execute*"${cmd_lower}"* ]]; then
            LAST_RESPONSE="$data"
            return 0
        fi
        sleep 0.1
    done

    LAST_RESPONSE=$(read_since "$file" "$offset")
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
        fail "  got      : $(printf '%s' "$response"  | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_error() {
    local label="$1" response="$2"
    local lowered
    lowered=$(printf '%s' "$response" | tr '[:upper:]' '[:lower:]')

    if [[ "$lowered" == -*err* ]]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected an ERR response"
        fail "  got      : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_subscribed_mode_error() {
    local label="$1" response="$2" command="$3"
    local lowered cmd_lower
    lowered=$(printf '%s' "$response" | tr '[:upper:]' '[:lower:]')
    cmd_lower=$(printf '%s' "$command" | tr '[:upper:]' '[:lower:]')

    if [[ "$lowered" == -*err*execute*"${cmd_lower}"* ]]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected subscribed-mode ERR for command '$command'"
        fail "  got      : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

send_and_expect_client() {
    local idx="$1" label="$2" expected="$3"
    shift 3
    local out="${SUB_OUTS[$idx]}"
    local offset
    offset=$(file_size "$out")

    send_client "$idx" "$@"
    if wait_for_expected_since "$out" "$offset" "$expected"; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected : $(printf '%s' "$expected" | cat -A)"
        fail "  got      : $(printf '%s' "$LAST_RESPONSE" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

send_and_expect_client_error() {
    local idx="$1" label="$2" mode_command="$3"
    shift 3
    local out="${SUB_OUTS[$idx]}"
    local offset
    offset=$(file_size "$out")

    send_client "$idx" "$@"
    if wait_for_subscribed_mode_error_since "$out" "$offset" "$mode_command"; then
        check_subscribed_mode_error "$label" "$LAST_RESPONSE" "$mode_command"
    else
        fail "$label"
        fail "  expected subscribed-mode ERR for command '$mode_command'"
        fail "  got      : $(printf '%s' "$LAST_RESPONSE" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

wait_for_growth() {
    local file="$1"
    local offset="$2"
    local attempts="${3:-30}"
    local i size

    for i in $(seq 1 "$attempts"); do
        size=$(file_size "$file")
        if [ "$size" -gt "$offset" ]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

check_no_growth() {
    local label="$1" idx="$2" offset="$3"
    local wait_seconds="${4:-0.4}"
    local out="${SUB_OUTS[$idx]}"
    local before after

    before=$(file_size "$out")
    sleep "$wait_seconds"
    after=$(file_size "$out")

    if [ "$before" = "$offset" ] && [ "$after" = "$offset" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  output grew from offset $offset to $after"
        fail "  new data : $(read_since "$out" "$offset" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

expect_int() {
    printf ':%d\r' "$1"
}

expect_ok() {
    printf '+OK\r'
}

expect_simple() {
    printf '+%s\r' "$1"
}

expect_pubsub_ack_frame() {
    local kind="$1"
    local channel="$2"
    local count="$3"
    printf '*3\r\n'
    printf '$%d\r\n%s\r\n' "${#kind}" "$kind"
    printf '$%d\r\n%s\r\n' "${#channel}" "$channel"
    printf ':%d\r\n' "$count"
}

expect_message_frame() {
    local channel="$1"
    local message="$2"
    printf '*3\r\n'
    printf '$7\r\nmessage\r\n'
    printf '$%d\r\n%s\r\n' "${#channel}" "$channel"
    printf '$%d\r\n%s\r\n' "${#message}" "$message"
}

expect_subscribed_pong() {
    printf '*2\r\n$4\r\npong\r\n$0\r\n\r\n'
}

expect_unsubscribe_empty_ack() {
    printf '*3\r\n$11\r\nunsubscribe\r\n$-1\r\n:0\r\n'
}

# ---------------------------------------------------------------------------
# Test 1: Basic SUBSCRIBE and per-client channel counts
# ---------------------------------------------------------------------------
start_pubsub_client alpha
ALPHA=$NEW_CLIENT_ID
send_and_expect_client "$ALPHA" "SUBSCRIBE foo -> [subscribe,foo,1]" \
    "$(expect_pubsub_ack_frame subscribe foo 1)" SUBSCRIBE foo

send_and_expect_client "$ALPHA" "SUBSCRIBE bar on same client -> count 2" \
    "$(expect_pubsub_ack_frame subscribe bar 2)" SUBSCRIBE bar

send_and_expect_client "$ALPHA" "Duplicate SUBSCRIBE bar keeps count 2" \
    "$(expect_pubsub_ack_frame subscribe bar 2)" SUBSCRIBE bar

start_pubsub_client beta
BETA=$NEW_CLIENT_ID
send_and_expect_client "$BETA" "Second client SUBSCRIBE foo has independent count 1" \
    "$(expect_pubsub_ack_frame subscribe foo 1)" SUBSCRIBE foo

send_and_expect_client "$BETA" "Second client SUBSCRIBE baz -> count 2" \
    "$(expect_pubsub_ack_frame subscribe baz 2)" SUBSCRIBE baz

# ---------------------------------------------------------------------------
# Test 2: Subscribed mode command filtering and PING behavior
# ---------------------------------------------------------------------------
send_and_expect_client_error "$ALPHA" "SET is rejected in subscribed mode" SET \
    SET pubsub_key value

send_and_expect_client_error "$ALPHA" "GET is rejected in subscribed mode" GET \
    GET pubsub_key

send_and_expect_client_error "$ALPHA" "ECHO is rejected in subscribed mode" ECHO \
    ECHO hello

send_and_expect_client_error "$ALPHA" "PUBLISH is rejected from subscribed client" PUBLISH \
    PUBLISH foo should_not_publish

send_and_expect_client "$ALPHA" "PING in subscribed mode -> [pong,empty]" \
    "$(expect_subscribed_pong)" PING

response=$(send_cmd PING)
check "PING from an unsubscribed client -> +PONG" "$response" "$(expect_simple PONG)"

send_and_expect_client "$ALPHA" "Lowercase subscribe is allowed in subscribed mode" \
    "$(expect_pubsub_ack_frame subscribe qux 3)" subscribe qux

# ---------------------------------------------------------------------------
# Test 3: PUBLISH counts and delivery to subscribed clients only
# ---------------------------------------------------------------------------
ALPHA_FOO_OFFSET=$(file_size "${SUB_OUTS[$ALPHA]}")
BETA_FOO_OFFSET=$(file_size "${SUB_OUTS[$BETA]}")

response=$(send_cmd PUBLISH foo before_unsubscribe)
check "PUBLISH foo counts alpha+beta -> :2" "$response" "$(expect_int 2)"

wait_for_expected_since "${SUB_OUTS[$ALPHA]}" "$ALPHA_FOO_OFFSET" \
    "$(expect_message_frame foo before_unsubscribe)"
check "Alpha receives foo message" "$LAST_RESPONSE" \
    "$(expect_message_frame foo before_unsubscribe)"

wait_for_expected_since "${SUB_OUTS[$BETA]}" "$BETA_FOO_OFFSET" \
    "$(expect_message_frame foo before_unsubscribe)"
check "Beta receives foo message" "$LAST_RESPONSE" \
    "$(expect_message_frame foo before_unsubscribe)"

ALPHA_BAZ_OFFSET=$(file_size "${SUB_OUTS[$ALPHA]}")
BETA_BAZ_OFFSET=$(file_size "${SUB_OUTS[$BETA]}")

response=$(send_cmd PUBLISH baz beta_only)
check "PUBLISH baz counts beta only -> :1" "$response" "$(expect_int 1)"

wait_for_expected_since "${SUB_OUTS[$BETA]}" "$BETA_BAZ_OFFSET" \
    "$(expect_message_frame baz beta_only)"
check "Beta receives baz message" "$LAST_RESPONSE" \
    "$(expect_message_frame baz beta_only)"
check_no_growth "Alpha does not receive baz message" "$ALPHA" "$ALPHA_BAZ_OFFSET"

ALPHA_BAR_OFFSET=$(file_size "${SUB_OUTS[$ALPHA]}")
BETA_BAR_OFFSET=$(file_size "${SUB_OUTS[$BETA]}")

response=$(send_cmd PUBLISH bar alpha_only)
check "PUBLISH bar counts alpha only despite duplicate SUBSCRIBE -> :1" \
    "$response" "$(expect_int 1)"

wait_for_expected_since "${SUB_OUTS[$ALPHA]}" "$ALPHA_BAR_OFFSET" \
    "$(expect_message_frame bar alpha_only)"
check "Alpha receives exactly one bar message" "$LAST_RESPONSE" \
    "$(expect_message_frame bar alpha_only)"
check_no_growth "Alpha duplicate subscription does not produce a second bar message" \
    "$ALPHA" "$(file_size "${SUB_OUTS[$ALPHA]}")"
check_no_growth "Beta does not receive bar message" "$BETA" "$BETA_BAR_OFFSET"

response=$(send_cmd PUBLISH no_subscribers lonely)
check "PUBLISH no_subscribers -> :0" "$response" "$(expect_int 0)"

# ---------------------------------------------------------------------------
# Test 4: Case-sensitive channels, channels with spaces, and empty payloads
# ---------------------------------------------------------------------------
start_pubsub_client gamma
GAMMA=$NEW_CLIENT_ID
send_and_expect_client "$GAMMA" "SUBSCRIBE Foo uses a distinct case-sensitive channel" \
    "$(expect_pubsub_ack_frame subscribe Foo 1)" SUBSCRIBE Foo

ALPHA_CASE_OFFSET=$(file_size "${SUB_OUTS[$ALPHA]}")
BETA_CASE_OFFSET=$(file_size "${SUB_OUTS[$BETA]}")
GAMMA_OFFSET=$(file_size "${SUB_OUTS[$GAMMA]}")
response=$(send_cmd PUBLISH foo lowercase_only)
check "PUBLISH foo does not count Foo subscriber -> :2" "$response" "$(expect_int 2)"
wait_for_expected_since "${SUB_OUTS[$ALPHA]}" "$ALPHA_CASE_OFFSET" \
    "$(expect_message_frame foo lowercase_only)"
check "Alpha receives lowercase foo case-sensitivity probe" "$LAST_RESPONSE" \
    "$(expect_message_frame foo lowercase_only)"
wait_for_expected_since "${SUB_OUTS[$BETA]}" "$BETA_CASE_OFFSET" \
    "$(expect_message_frame foo lowercase_only)"
check "Beta receives lowercase foo case-sensitivity probe" "$LAST_RESPONSE" \
    "$(expect_message_frame foo lowercase_only)"
check_no_growth "Gamma subscribed to Foo does not receive foo" "$GAMMA" "$GAMMA_OFFSET"

GAMMA_OFFSET=$(file_size "${SUB_OUTS[$GAMMA]}")
response=$(send_cmd PUBLISH Foo uppercase_only)
check "PUBLISH Foo counts gamma -> :1" "$response" "$(expect_int 1)"
wait_for_expected_since "${SUB_OUTS[$GAMMA]}" "$GAMMA_OFFSET" \
    "$(expect_message_frame Foo uppercase_only)"
check "Gamma receives Foo message" "$LAST_RESPONSE" \
    "$(expect_message_frame Foo uppercase_only)"

start_pubsub_client delta
DELTA=$NEW_CLIENT_ID
send_and_expect_client "$DELTA" "SUBSCRIBE channel containing spaces" \
    "$(expect_pubsub_ack_frame subscribe "space channel" 1)" SUBSCRIBE "space channel"

DELTA_OFFSET=$(file_size "${SUB_OUTS[$DELTA]}")
response=$(send_cmd PUBLISH "space channel" "message with spaces")
check "PUBLISH channel with spaces -> :1" "$response" "$(expect_int 1)"
wait_for_expected_since "${SUB_OUTS[$DELTA]}" "$DELTA_OFFSET" \
    "$(expect_message_frame "space channel" "message with spaces")"
check "Delta receives message with spaces" "$LAST_RESPONSE" \
    "$(expect_message_frame "space channel" "message with spaces")"

send_and_expect_client "$DELTA" "SUBSCRIBE empty channel name" \
    "$(expect_pubsub_ack_frame subscribe "" 2)" SUBSCRIBE ""

DELTA_EMPTY_OFFSET=$(file_size "${SUB_OUTS[$DELTA]}")
response=$(send_cmd PUBLISH "" "")
check "PUBLISH empty channel and empty message -> :1" "$response" "$(expect_int 1)"
wait_for_expected_since "${SUB_OUTS[$DELTA]}" "$DELTA_EMPTY_OFFSET" \
    "$(expect_message_frame "" "")"
check "Delta receives empty-channel empty-message delivery" "$LAST_RESPONSE" \
    "$(expect_message_frame "" "")"

# ---------------------------------------------------------------------------
# Test 5: Large batch of channels and longer messages
# ---------------------------------------------------------------------------
start_pubsub_client batch
BATCH=$NEW_CLIENT_ID
for i in $(seq 1 12); do
    send_and_expect_client "$BATCH" "Batch SUBSCRIBE chan_$i -> count $i" \
        "$(expect_pubsub_ack_frame subscribe "chan_$i" "$i")" SUBSCRIBE "chan_$i"
done

LONG_MESSAGE="long-message-000000000111111111122222222223333333333444444444455555555556666666666777777777788888888889999999999"
for i in $(seq 1 12); do
    BATCH_OFFSET=$(file_size "${SUB_OUTS[$BATCH]}")
    response=$(send_cmd PUBLISH "chan_$i" "$LONG_MESSAGE-$i")
    check "PUBLISH chan_$i counts batch subscriber -> :1" "$response" "$(expect_int 1)"
    wait_for_expected_since "${SUB_OUTS[$BATCH]}" "$BATCH_OFFSET" \
        "$(expect_message_frame "chan_$i" "$LONG_MESSAGE-$i")"
    check "Batch client receives chan_$i long message" "$LAST_RESPONSE" \
        "$(expect_message_frame "chan_$i" "$LONG_MESSAGE-$i")"
done

# ---------------------------------------------------------------------------
# Test 6: Many sequential SUBSCRIBE/UNSUBSCRIBE commands on one connection
# ---------------------------------------------------------------------------
start_pubsub_client multi
MULTI=$NEW_CLIENT_ID
send_and_expect_client "$MULTI" "SUBSCRIBE multi_1 -> count 1" \
    "$(expect_pubsub_ack_frame subscribe multi_1 1)" SUBSCRIBE multi_1

send_and_expect_client "$MULTI" "SUBSCRIBE multi_2 -> count 2" \
    "$(expect_pubsub_ack_frame subscribe multi_2 2)" SUBSCRIBE multi_2

send_and_expect_client "$MULTI" "Duplicate SUBSCRIBE multi_1 keeps count 2" \
    "$(expect_pubsub_ack_frame subscribe multi_1 2)" SUBSCRIBE multi_1

send_and_expect_client "$MULTI" "SUBSCRIBE multi_3 -> count 3" \
    "$(expect_pubsub_ack_frame subscribe multi_3 3)" SUBSCRIBE multi_3

send_and_expect_client "$MULTI" "UNSUBSCRIBE multi_1 -> count 2" \
    "$(expect_pubsub_ack_frame unsubscribe multi_1 2)" UNSUBSCRIBE multi_1

send_and_expect_client "$MULTI" "UNSUBSCRIBE missing_multi keeps count 2" \
    "$(expect_pubsub_ack_frame unsubscribe missing_multi 2)" UNSUBSCRIBE missing_multi

send_and_expect_client "$MULTI" "UNSUBSCRIBE multi_3 -> count 1" \
    "$(expect_pubsub_ack_frame unsubscribe multi_3 1)" UNSUBSCRIBE multi_3

MULTI_OFFSET=$(file_size "${SUB_OUTS[$MULTI]}")
response=$(send_cmd PUBLISH multi_1 after_unsub)
check "PUBLISH multi_1 after UNSUBSCRIBE -> :0" "$response" "$(expect_int 0)"
check_no_growth "Multi client no longer receives multi_1" "$MULTI" "$MULTI_OFFSET"

MULTI_OFFSET=$(file_size "${SUB_OUTS[$MULTI]}")
response=$(send_cmd PUBLISH multi_2 still_subscribed)
check "PUBLISH multi_2 still has one subscriber -> :1" "$response" "$(expect_int 1)"
wait_for_expected_since "${SUB_OUTS[$MULTI]}" "$MULTI_OFFSET" \
    "$(expect_message_frame multi_2 still_subscribed)"
check "Multi client still receives multi_2" "$LAST_RESPONSE" \
    "$(expect_message_frame multi_2 still_subscribed)"

# ---------------------------------------------------------------------------
# Test 7: UNSUBSCRIBE updates delivery sets and leaves subscribed mode at zero
# ---------------------------------------------------------------------------
send_and_expect_client "$ALPHA" "UNSUBSCRIBE foo from alpha -> count 2" \
    "$(expect_pubsub_ack_frame unsubscribe foo 2)" UNSUBSCRIBE foo

ALPHA_AFTER_UNSUB_OFFSET=$(file_size "${SUB_OUTS[$ALPHA]}")
BETA_AFTER_UNSUB_OFFSET=$(file_size "${SUB_OUTS[$BETA]}")
response=$(send_cmd PUBLISH foo after_alpha_unsub)
check "PUBLISH foo after alpha unsubscribed counts beta only -> :1" \
    "$response" "$(expect_int 1)"

wait_for_expected_since "${SUB_OUTS[$BETA]}" "$BETA_AFTER_UNSUB_OFFSET" \
    "$(expect_message_frame foo after_alpha_unsub)"
check "Beta receives foo after alpha unsubscribed" "$LAST_RESPONSE" \
    "$(expect_message_frame foo after_alpha_unsub)"
check_no_growth "Alpha no longer receives foo after UNSUBSCRIBE" \
    "$ALPHA" "$ALPHA_AFTER_UNSUB_OFFSET"

send_and_expect_client "$BETA" "UNSUBSCRIBE missing channel keeps beta count 2" \
    "$(expect_pubsub_ack_frame unsubscribe not_subscribed 2)" UNSUBSCRIBE not_subscribed

send_and_expect_client "$BETA" "UNSUBSCRIBE foo from beta -> count 1" \
    "$(expect_pubsub_ack_frame unsubscribe foo 1)" UNSUBSCRIBE foo

send_and_expect_client "$BETA" "UNSUBSCRIBE baz from beta -> count 0" \
    "$(expect_pubsub_ack_frame unsubscribe baz 0)" UNSUBSCRIBE baz

send_and_expect_client "$BETA" "SET is allowed again after all subscriptions are removed" \
    "$(expect_ok)" SET after_unsubscribe allowed
check_no_growth "No extra data after SET on unsubscribed beta" "$BETA" \
    "$(file_size "${SUB_OUTS[$BETA]}")" 0.2

response=$(send_cmd GET after_unsubscribe)
check "GET after_unsubscribe confirms beta left subscribed mode" "$response" \
    "$(printf '$7\r\nallowed\r')"

# ---------------------------------------------------------------------------
# Test 8: Invalid and empty argument cases
# ---------------------------------------------------------------------------
response=$(send_cmd SUBSCRIBE)
check_error "SUBSCRIBE with no channels returns an error" "$response"

response=$(send_cmd PUBLISH)
check_error "PUBLISH with no arguments returns an error" "$response"

response=$(send_cmd PUBLISH only_channel)
check_error "PUBLISH missing message returns an error" "$response"

response=$(send_cmd PUBLISH too many args here)
check_error "PUBLISH with too many arguments returns an error" "$response"

response=$(send_cmd UNSUBSCRIBE)
if [ "$response" = "$(expect_unsubscribe_empty_ack)" ]; then
    pass "UNSUBSCRIBE with no channels returns Redis-style empty unsubscribe ack"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    check_error "UNSUBSCRIBE with no channels may also be rejected as empty input" "$response"
fi

# ---------------------------------------------------------------------------
cleanup_pubsub_clients
rm -rf "$TMPDIR_LOCAL"
stop_server_bounded
trap - EXIT

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Pub/Sub command tests passed."
else
    exit 1
fi
