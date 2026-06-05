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
    (
        {
            write_resp_command BLPOP "$key" 0
            sleep 8
        } | timeout 9 nc 127.0.0.1 6379 > "$outfile" 2>/dev/null
    ) &
    BLPOP_PID=$!
}

wait_for_response() {
    local file="$1" i
    for i in $(seq 1 30); do
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
rm -rf "$TMPDIR_LOCAL"
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 13 passed."
else
    exit 1
fi
