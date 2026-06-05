#!/bin/bash
# Stage 13: Verify BLPOP blocks until LPUSH/RPUSH provides an element

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 13: BLPOP command ==="

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

expect_int()  { printf ':%d\r' "$1"; }
expect_null() { printf '$-1\r'; }
expect_null_array() { printf '*-1\r'; }

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
# Test 1: BLPOP blocks on an empty list until RPUSH adds an element
# ---------------------------------------------------------------------------
RESP1="$TMPDIR_LOCAL/blpop_basic"
start_blpop "$RESP1" blpop_list
PID1=$BLPOP_PID

sleep 0.3
check_no_response "BLPOP empty list blocks before RPUSH" "$RESP1"

response=$(send_cmd RPUSH blpop_list foo)
check "RPUSH wakes one BLPOP client → :1" "$response" "$(expect_int 1)"

if wait_for_response "$RESP1"; then
    response=$(cat "$RESP1")
    check "BLPOP response → [blpop_list,foo]" "$response" "$(expect_array blpop_list foo)"
else
    fail "BLPOP did not receive response after RPUSH"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_client "$PID1"

response=$(send_cmd LPOP blpop_list)
check "BLPOP removes the popped element" "$response" "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 2: Multiple blocked clients on one list are served oldest first
# ---------------------------------------------------------------------------
RESP_FIRST="$TMPDIR_LOCAL/blpop_first"
RESP_SECOND="$TMPDIR_LOCAL/blpop_second"

start_blpop "$RESP_FIRST" blpop_fifo
PID_FIRST=$BLPOP_PID
sleep 0.2
start_blpop "$RESP_SECOND" blpop_fifo
PID_SECOND=$BLPOP_PID

sleep 0.3
check_no_response "Both BLPOP clients are blocked before RPUSH (first)" "$RESP_FIRST"
check_no_response "Both BLPOP clients are blocked before RPUSH (second)" "$RESP_SECOND"

response=$(send_cmd RPUSH blpop_fifo first_value)
check "First RPUSH with two blocked clients → :1" "$response" "$(expect_int 1)"

if wait_for_response "$RESP_FIRST"; then
    response=$(cat "$RESP_FIRST")
    check "Oldest BLPOP client receives first pushed value" "$response" \
        "$(expect_array blpop_fifo first_value)"
else
    fail "Oldest BLPOP client did not receive first pushed value"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

sleep 0.3
check_no_response "Second BLPOP client remains blocked after one RPUSH" "$RESP_SECOND"

response=$(send_cmd RPUSH blpop_fifo second_value)
check "Second RPUSH wakes remaining BLPOP client → :1" "$response" "$(expect_int 1)"

if wait_for_response "$RESP_SECOND"; then
    response=$(cat "$RESP_SECOND")
    check "Second BLPOP client receives second pushed value" "$response" \
        "$(expect_array blpop_fifo second_value)"
else
    fail "Second BLPOP client did not receive second pushed value"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

cleanup_client "$PID_FIRST"
cleanup_client "$PID_SECOND"

# ---------------------------------------------------------------------------
# Test 3: BLPOP on a non-empty list returns immediately with the leftmost item
# ---------------------------------------------------------------------------
send_cmd RPUSH ready_list left right > /dev/null

response=$(send_cmd BLPOP ready_list 0)
check "BLPOP non-empty list → [ready_list,left]" "$response" "$(expect_array ready_list left)"

response=$(send_cmd LPOP ready_list)
check "BLPOP leaves remaining tail element" "$response" "$(printf '$5\r\nright\r')"

# ---------------------------------------------------------------------------
# Test 4: Case-insensitive command — lowercase blpop
# ---------------------------------------------------------------------------
send_cmd RPUSH lc_blpop alpha > /dev/null

response=$(send_cmd blpop lc_blpop 0)
check "blpop (lowercase) → [lc_blpop,alpha]" "$response" "$(expect_array lc_blpop alpha)"

# ---------------------------------------------------------------------------
# Test 5: RPUSH + LPUSH + BLPOP preserve left-to-right list order
#
# RPUSH mixed_ready middle right → [middle,right]
# LPUSH mixed_ready left         → [left,middle,right]
# BLPOP should pop left first, then middle.
# ---------------------------------------------------------------------------
send_cmd RPUSH mixed_ready middle right > /dev/null
response=$(send_cmd LPUSH mixed_ready left)
check "LPUSH before BLPOP on RPUSH-created list → :3" "$response" "$(expect_int 3)"

response=$(send_cmd BLPOP mixed_ready 0)
check "BLPOP after RPUSH+LPUSH pops leftmost LPUSH value" "$response" \
    "$(expect_array mixed_ready left)"

response=$(send_cmd BLPOP mixed_ready 0)
check "Next BLPOP pops original RPUSH head" "$response" \
    "$(expect_array mixed_ready middle)"

response=$(send_cmd LPOP mixed_ready)
check "Remaining mixed list tail is right" "$response" "$(printf '$5\r\nright\r')"

# ---------------------------------------------------------------------------
# Test 6: Multiple blocked clients are served oldest first across LPUSH/RPUSH
# ---------------------------------------------------------------------------
RESP_MIX_FIRST="$TMPDIR_LOCAL/blpop_mix_first"
RESP_MIX_SECOND="$TMPDIR_LOCAL/blpop_mix_second"

start_blpop "$RESP_MIX_FIRST" blocked_mix
PID_MIX_FIRST=$BLPOP_PID
sleep 0.2
start_blpop "$RESP_MIX_SECOND" blocked_mix
PID_MIX_SECOND=$BLPOP_PID

sleep 0.3
check_no_response "Mixed push clients blocked before LPUSH (first)" "$RESP_MIX_FIRST"
check_no_response "Mixed push clients blocked before LPUSH (second)" "$RESP_MIX_SECOND"

response=$(send_cmd LPUSH blocked_mix from_left)
check "LPUSH wakes oldest BLPOP client → :1" "$response" "$(expect_int 1)"

if wait_for_response "$RESP_MIX_FIRST"; then
    response=$(cat "$RESP_MIX_FIRST")
    check "Oldest BLPOP receives LPUSH value" "$response" \
        "$(expect_array blocked_mix from_left)"
else
    fail "Oldest BLPOP client did not receive LPUSH value"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

sleep 0.3
check_no_response "Second BLPOP remains blocked after LPUSH wakes first" "$RESP_MIX_SECOND"

response=$(send_cmd RPUSH blocked_mix from_right)
check "RPUSH wakes remaining BLPOP client → :1" "$response" "$(expect_int 1)"

if wait_for_response "$RESP_MIX_SECOND"; then
    response=$(cat "$RESP_MIX_SECOND")
    check "Second BLPOP receives RPUSH value" "$response" \
        "$(expect_array blocked_mix from_right)"
else
    fail "Second BLPOP client did not receive RPUSH value"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

cleanup_client "$PID_MIX_FIRST"
cleanup_client "$PID_MIX_SECOND"

# ---------------------------------------------------------------------------
# Test 7: Three blocked clients with alternating LPUSH/RPUSH values
# ---------------------------------------------------------------------------
RESP_TRI_FIRST="$TMPDIR_LOCAL/blpop_tri_first"
RESP_TRI_SECOND="$TMPDIR_LOCAL/blpop_tri_second"
RESP_TRI_THIRD="$TMPDIR_LOCAL/blpop_tri_third"

start_blpop "$RESP_TRI_FIRST" tri_mix
PID_TRI_FIRST=$BLPOP_PID
sleep 0.15
start_blpop "$RESP_TRI_SECOND" tri_mix
PID_TRI_SECOND=$BLPOP_PID
sleep 0.15
start_blpop "$RESP_TRI_THIRD" tri_mix
PID_TRI_THIRD=$BLPOP_PID

sleep 0.3
check_no_response "Three-client mix blocked before first push (first)" "$RESP_TRI_FIRST"
check_no_response "Three-client mix blocked before first push (second)" "$RESP_TRI_SECOND"
check_no_response "Three-client mix blocked before first push (third)" "$RESP_TRI_THIRD"

response=$(send_cmd RPUSH tri_mix r1)
check "RPUSH wakes first of three blocked clients → :1" "$response" "$(expect_int 1)"

if wait_for_response "$RESP_TRI_FIRST"; then
    response=$(cat "$RESP_TRI_FIRST")
    check "First of three receives first RPUSH value" "$response" "$(expect_array tri_mix r1)"
else
    fail "First of three BLPOP clients did not receive first RPUSH value"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

sleep 0.2
check_no_response "Second of three still blocked after first push" "$RESP_TRI_SECOND"
check_no_response "Third of three still blocked after first push" "$RESP_TRI_THIRD"

response=$(send_cmd LPUSH tri_mix l2)
check "LPUSH wakes second of three blocked clients → :1" "$response" "$(expect_int 1)"

if wait_for_response "$RESP_TRI_SECOND"; then
    response=$(cat "$RESP_TRI_SECOND")
    check "Second of three receives LPUSH value" "$response" "$(expect_array tri_mix l2)"
else
    fail "Second of three BLPOP clients did not receive LPUSH value"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

sleep 0.2
check_no_response "Third of three still blocked after two pushes" "$RESP_TRI_THIRD"

response=$(send_cmd RPUSH tri_mix r3)
check "Final RPUSH wakes third blocked client → :1" "$response" "$(expect_int 1)"

if wait_for_response "$RESP_TRI_THIRD"; then
    response=$(cat "$RESP_TRI_THIRD")
    check "Third of three receives final RPUSH value" "$response" "$(expect_array tri_mix r3)"
else
    fail "Third of three BLPOP clients did not receive final RPUSH value"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

cleanup_client "$PID_TRI_FIRST"
cleanup_client "$PID_TRI_SECOND"
cleanup_client "$PID_TRI_THIRD"

# ---------------------------------------------------------------------------
# Test 8: BLPOP with a non-zero timeout returns a null array when it expires
# ---------------------------------------------------------------------------
RESP_TIMEOUT="$TMPDIR_LOCAL/blpop_timeout"
start_blpop "$RESP_TIMEOUT" timeout_empty 0.2
PID_TIMEOUT=$BLPOP_PID

if wait_for_response "$RESP_TIMEOUT"; then
    response=$(cat "$RESP_TIMEOUT")
    check "BLPOP 0.2 timeout on empty list → null array" "$response" \
        "$(expect_null_array)"
else
    fail "BLPOP 0.2 did not return after timeout"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

cleanup_client "$PID_TIMEOUT"

# ---------------------------------------------------------------------------
# Test 9: RPUSH before a non-zero timeout unblocks BLPOP with the pushed value
# ---------------------------------------------------------------------------
RESP_TIMEOUT_RPUSH="$TMPDIR_LOCAL/blpop_timeout_rpush"
start_blpop "$RESP_TIMEOUT_RPUSH" timeout_rpush 1
PID_TIMEOUT_RPUSH=$BLPOP_PID

sleep 0.2
check_no_response "BLPOP 1 waits before RPUSH arrives" "$RESP_TIMEOUT_RPUSH"

response=$(send_cmd RPUSH timeout_rpush foo)
check "RPUSH before BLPOP timeout → :1" "$response" "$(expect_int 1)"

if wait_for_response "$RESP_TIMEOUT_RPUSH"; then
    response=$(cat "$RESP_TIMEOUT_RPUSH")
    check "BLPOP before timeout receives RPUSH value" "$response" \
        "$(expect_array timeout_rpush foo)"
else
    fail "BLPOP did not receive RPUSH value before timeout"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

cleanup_client "$PID_TIMEOUT_RPUSH"

# ---------------------------------------------------------------------------
# Test 10: LPUSH before a non-zero timeout also unblocks BLPOP
# ---------------------------------------------------------------------------
RESP_TIMEOUT_LPUSH="$TMPDIR_LOCAL/blpop_timeout_lpush"
start_blpop "$RESP_TIMEOUT_LPUSH" timeout_lpush 1
PID_TIMEOUT_LPUSH=$BLPOP_PID

sleep 0.2
check_no_response "BLPOP 1 waits before LPUSH arrives" "$RESP_TIMEOUT_LPUSH"

response=$(send_cmd LPUSH timeout_lpush lefty)
check "LPUSH before BLPOP timeout → :1" "$response" "$(expect_int 1)"

if wait_for_response "$RESP_TIMEOUT_LPUSH"; then
    response=$(cat "$RESP_TIMEOUT_LPUSH")
    check "BLPOP before timeout receives LPUSH value" "$response" \
        "$(expect_array timeout_lpush lefty)"
else
    fail "BLPOP did not receive LPUSH value before timeout"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

cleanup_client "$PID_TIMEOUT_LPUSH"

# ---------------------------------------------------------------------------
# Test 11: Timed-out clients are skipped; remaining blocked clients can be woken
# ---------------------------------------------------------------------------
RESP_SHORT_TIMEOUT="$TMPDIR_LOCAL/blpop_short_timeout"
RESP_LONG_TIMEOUT="$TMPDIR_LOCAL/blpop_long_timeout"

start_blpop "$RESP_SHORT_TIMEOUT" timeout_fifo 0.2
PID_SHORT_TIMEOUT=$BLPOP_PID
sleep 0.1
start_blpop "$RESP_LONG_TIMEOUT" timeout_fifo 1
PID_LONG_TIMEOUT=$BLPOP_PID

if wait_for_response "$RESP_SHORT_TIMEOUT"; then
    response=$(cat "$RESP_SHORT_TIMEOUT")
    check "Oldest BLPOP times out with null array" "$response" "$(expect_null_array)"
else
    fail "Oldest BLPOP did not time out"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

sleep 0.1
check_no_response "Younger BLPOP remains blocked after older timeout" "$RESP_LONG_TIMEOUT"

response=$(send_cmd RPUSH timeout_fifo survivor)
check "RPUSH wakes younger non-expired BLPOP → :1" "$response" "$(expect_int 1)"

if wait_for_response "$RESP_LONG_TIMEOUT"; then
    response=$(cat "$RESP_LONG_TIMEOUT")
    check "Younger BLPOP receives value after older timeout" "$response" \
        "$(expect_array timeout_fifo survivor)"
else
    fail "Younger BLPOP did not receive value after older timeout"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

cleanup_client "$PID_SHORT_TIMEOUT"
cleanup_client "$PID_LONG_TIMEOUT"

# ---------------------------------------------------------------------------
# Test 12: Race at the timeout boundary with multiple waiting clients
#
# The first client is intentionally close to its timeout when RPUSH happens.
# Either outcome is acceptable at the boundary:
# - if the push wins, client 1 gets racing_value and client 2 gets follow_up
# - if the timeout wins, client 1 gets null, client 2 gets racing_value,
#   and client 3 gets follow_up
#
# In both cases, the pushed values must be delivered exactly once and FIFO
# order among non-expired clients must be preserved.
# ---------------------------------------------------------------------------
RESP_RACE_FIRST="$TMPDIR_LOCAL/blpop_race_first"
RESP_RACE_SECOND="$TMPDIR_LOCAL/blpop_race_second"
RESP_RACE_THIRD="$TMPDIR_LOCAL/blpop_race_third"

start_blpop "$RESP_RACE_FIRST" timeout_race 0.45
PID_RACE_FIRST=$BLPOP_PID
sleep 0.05
start_blpop "$RESP_RACE_SECOND" timeout_race 3
PID_RACE_SECOND=$BLPOP_PID
sleep 0.05
start_blpop "$RESP_RACE_THIRD" timeout_race 3
PID_RACE_THIRD=$BLPOP_PID

sleep 0.35
response=$(send_cmd RPUSH timeout_race racing_value)
check "Boundary RPUSH during timeout race → :1" "$response" "$(expect_int 1)"

sleep 0.2
RACE_FIRST_RESPONSE=""
RACE_SECOND_RESPONSE=""
[ -s "$RESP_RACE_FIRST" ] && RACE_FIRST_RESPONSE=$(cat "$RESP_RACE_FIRST")
[ -s "$RESP_RACE_SECOND" ] && RACE_SECOND_RESPONSE=$(cat "$RESP_RACE_SECOND")

if [ "$RACE_FIRST_RESPONSE" = "$(expect_array timeout_race racing_value)" ]; then
    pass "Timeout race: push reached oldest client before timeout"
    PASS_COUNT=$((PASS_COUNT + 1))
    check_no_response "Timeout race: second client still waits after first wins" \
        "$RESP_RACE_SECOND"
    check_no_response "Timeout race: third client still waits after first wins" \
        "$RESP_RACE_THIRD"

    response=$(send_cmd RPUSH timeout_race follow_up)
    check "Timeout race follow-up RPUSH wakes second client → :1" "$response" \
        "$(expect_int 1)"

    if wait_for_response "$RESP_RACE_SECOND" 10; then
        response=$(cat "$RESP_RACE_SECOND")
        check "Timeout race: second client receives follow-up value" "$response" \
            "$(expect_array timeout_race follow_up)"
    else
        fail "Timeout race: second client did not receive follow-up value"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    check_no_response "Timeout race: third client remains blocked after two pushes" \
        "$RESP_RACE_THIRD"
elif [ "$RACE_FIRST_RESPONSE" = "$(expect_null_array)" ]; then
    pass "Timeout race: oldest client timed out before push was fulfilled"
    PASS_COUNT=$((PASS_COUNT + 1))

    if [ -z "$RACE_SECOND_RESPONSE" ]; then
        wait_for_response "$RESP_RACE_SECOND" 10
        [ -s "$RESP_RACE_SECOND" ] && RACE_SECOND_RESPONSE=$(cat "$RESP_RACE_SECOND")
    fi

    check "Timeout race: second client receives racing value after first timeout" \
        "$RACE_SECOND_RESPONSE" "$(expect_array timeout_race racing_value)"
    check_no_response "Timeout race: third client waits after second wins racing value" \
        "$RESP_RACE_THIRD"

    response=$(send_cmd RPUSH timeout_race follow_up)
    check "Timeout race follow-up RPUSH wakes third client → :1" "$response" \
        "$(expect_int 1)"

    if wait_for_response "$RESP_RACE_THIRD" 10; then
        response=$(cat "$RESP_RACE_THIRD")
        check "Timeout race: third client receives follow-up value" "$response" \
            "$(expect_array timeout_race follow_up)"
    else
        fail "Timeout race: third client did not receive follow-up value"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    fail "Timeout race: first client got an unexpected response"
    fail "  got      : $(printf '%s' "$RACE_FIRST_RESPONSE" | cat -A)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

cleanup_client "$PID_RACE_FIRST"
cleanup_client "$PID_RACE_SECOND"
cleanup_client "$PID_RACE_THIRD"

# ---------------------------------------------------------------------------
rm -rf "$TMPDIR_LOCAL"
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 13 passed."
else
    exit 1
fi
