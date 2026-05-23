#!/bin/bash
# Stage 7: Verify SET with PX (millisecond) and EX (second) expiry options

source "$(dirname "$0")/helpers.sh"

echo "=== Stage 7: Key expiry (PX / EX) ==="

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Helpers — same pattern as test_set_get.sh to keep \r\n intact
# ---------------------------------------------------------------------------

# Write each RESP word to a temp file (no $() involved), pipe to nc
send_cmd() {
    local tmp
    tmp=$(mktemp)
    printf '*%d\r\n' "$#" > "$tmp"
    for word in "$@"; do
        printf '$%d\r\n%s\r\n' "${#word}" "$word" >> "$tmp"
    done
    nc -q 1 -W 1 127.0.0.1 6379 < "$tmp" 2>/dev/null
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

# Expected value builders.
# $() strips trailing \n, so responses arrive as "...\r" — builders match that.
expect_ok()   { printf '+OK\r'; }
expect_bulk() { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_null() { printf '$-1\r'; }

# ---------------------------------------------------------------------------
# Test 1: PX — key is readable before expiry
# ---------------------------------------------------------------------------
send_cmd SET px_key px_val PX 400 > /dev/null
response=$(send_cmd GET px_key)
check "PX: GET before expiry returns value" "$response" "$(expect_bulk px_val)"

# ---------------------------------------------------------------------------
# Test 2: PX — key becomes null after expiry
# ---------------------------------------------------------------------------
info "Waiting 500ms for PX key to expire..."
sleep 0.5
response=$(send_cmd GET px_key)
check "PX: GET after expiry returns null" "$response" "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 3: EX — key is readable before expiry
# ---------------------------------------------------------------------------
send_cmd SET ex_key ex_val EX 1 > /dev/null
response=$(send_cmd GET ex_key)
check "EX: GET before expiry returns value" "$response" "$(expect_bulk ex_val)"

# ---------------------------------------------------------------------------
# Test 4: EX — key becomes null after expiry
# ---------------------------------------------------------------------------
info "Waiting 1.1s for EX key to expire..."
sleep 1.1
response=$(send_cmd GET ex_key)
check "EX: GET after expiry returns null" "$response" "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 5: Case-insensitive — lowercase px
# ---------------------------------------------------------------------------
send_cmd SET lc_key lc_val px 300 > /dev/null
response=$(send_cmd GET lc_key)
check "px (lowercase): GET before expiry returns value" "$response" "$(expect_bulk lc_val)"
info "Waiting 400ms for lowercase px key to expire..."
sleep 0.4
response=$(send_cmd GET lc_key)
check "px (lowercase): GET after expiry returns null" "$response" "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 6: Case-insensitive — lowercase ex
# ---------------------------------------------------------------------------
send_cmd SET lc_ex_key lc_ex_val ex 1 > /dev/null
response=$(send_cmd GET lc_ex_key)
check "ex (lowercase): GET before expiry returns value" "$response" "$(expect_bulk lc_ex_val)"
info "Waiting 1.1s for lowercase ex key to expire..."
sleep 1.1
response=$(send_cmd GET lc_ex_key)
check "ex (lowercase): GET after expiry returns null" "$response" "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 7: Random key/value with PX (ensures nothing is hardcoded)
# ---------------------------------------------------------------------------
RAND_KEY=$(cat /dev/urandom | tr -dc 'a-z' | head -c 8)
RAND_VAL=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 10)

send_cmd SET "$RAND_KEY" "$RAND_VAL" PX 400 > /dev/null
response=$(send_cmd GET "$RAND_KEY")
check "PX random: GET before expiry returns correct value" "$response" "$(expect_bulk "$RAND_VAL")"
info "Waiting 500ms for random PX key to expire..."
sleep 0.5
response=$(send_cmd GET "$RAND_KEY")
check "PX random: GET after expiry returns null" "$response" "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 8: SET without expiry never expires (persists after other keys expire)
# ---------------------------------------------------------------------------
send_cmd SET persist_key persist_val > /dev/null
sleep 0.3
response=$(send_cmd GET persist_key)
check "No expiry: key persists after sleeping" "$response" "$(expect_bulk persist_val)"

# ---------------------------------------------------------------------------
# Test 9: Overwriting an expiring key with a plain SET clears the expiry
# ---------------------------------------------------------------------------
send_cmd SET overwrite_key will_expire PX 300 > /dev/null
send_cmd SET overwrite_key no_expiry       > /dev/null   # replaces, no TTL
info "Waiting 400ms to confirm overwritten key has no expiry..."
sleep 0.4
response=$(send_cmd GET overwrite_key)
check "Overwrite with plain SET clears expiry" "$response" "$(expect_bulk no_expiry)"

# ---------------------------------------------------------------------------
# Test 10: Very short PX (1ms) — key should be expired almost immediately
# ---------------------------------------------------------------------------
send_cmd SET flash_key flash_val PX 1 > /dev/null
sleep 0.05   # 50ms — well past 1ms expiry
response=$(send_cmd GET flash_key)
check "PX 1ms: key expired after 50ms sleep" "$response" "$(expect_null)"

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Stage 7 passed."
else
    exit 1
fi
