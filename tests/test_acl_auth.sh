#!/bin/bash
# Verify ACL WHOAMI, ACL GETUSER, ACL SETUSER, AUTH, and authentication enforcement

source "$(dirname "$0")/helpers.sh"

echo "=== Stage: ACL and AUTH commands ==="

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0
TMPDIR_LOCAL=$(mktemp -d)

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
    ) | timeout 8 nc -q 1 -W 4 127.0.0.1 6379 2>/dev/null
}

sha256_hex() {
    local value="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$value" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        printf '%s' "$value" | openssl dgst -sha256 -r | awk '{print $1}'
    else
        fail "No SHA-256 command found. Install sha256sum, shasum, or openssl."
        cleanup
        exit 1
    fi
}

cleanup() {
    rm -rf "$TMPDIR_LOCAL"
    stop_server
}

trap cleanup EXIT

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

check_prefix() {
    local label="$1" response="$2" prefix="$3"
    if [[ "$response" == "$prefix"* ]]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected prefix: $(printf '%s' "$prefix" | cat -A)"
        fail "  got            : $(printf '%s' "$response" | cat -A)"
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

check_error_or_null() {
    local label="$1" response="$2"
    if [[ "$response" == -* ]] || [ "$response" = "$(expect_null)" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected an error or null bulk response"
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

# Command substitution strips the final LF from CRLF, so each complete expected
# response ends with a trailing carriage return.
expect_ok()          { printf '+OK\r'; }
expect_pong()        { printf '+PONG\r'; }
expect_bulk()        { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_null()        { printf '$-1\r'; }
expect_simple()      { printf '+%s\r' "$1"; }
expect_error()       { printf -- '-%s\r' "$1"; }
expect_noauth()      { expect_error "NOAUTH Authentication required."; }
expect_wrongpass()   { printf -- '-WRONGPASS'; }

expect_concat() {
    local first=1 part
    for part in "$@"; do
        if [ "$first" -eq 1 ]; then
            printf '%s' "$part"
            first=0
        else
            printf '\n%s' "$part"
        fi
    done
}

expect_getuser() {
    local hashes=("$@")
    local count="${#hashes[@]}"
    local i

    printf '*4\r\n'
    printf '$5\r\nflags\r\n'
    if [ "$count" -eq 0 ]; then
        printf '*1\r\n$6\r\nnopass\r\n'
    else
        printf '*0\r\n'
    fi
    printf '$9\r\npasswords\r\n'
    printf '*%d' "$count"
    if [ "$count" -eq 0 ]; then
        printf '\r'
        return
    fi

    printf '\r\n'
    for i in $(seq 0 $((count - 1))); do
        if [ "$i" -eq $((count - 1)) ]; then
            printf '$64\r\n%s\r' "${hashes[$i]}"
        else
            printf '$64\r\n%s\r\n' "${hashes[$i]}"
        fi
    done
}

# ---------------------------------------------------------------------------
# Test 1: ACL WHOAMI before any password is configured
# ---------------------------------------------------------------------------
for command_case in "ACL WHOAMI" "acl whoami" "AcL WhOaMi"; do
    response=$(send_cmd $command_case)
    check "$command_case -> default user" "$response" "$(expect_bulk default)"
done

response=$(send_commands 2 ACL WHOAMI 1 PING 2 ACL WHOAMI)
check "Same nopass connection can run ACL WHOAMI, PING, ACL WHOAMI" "$response" \
    "$(expect_concat "$(expect_bulk default)" "$(expect_pong)" "$(expect_bulk default)")"

# ---------------------------------------------------------------------------
# Test 2-4: ACL GETUSER default reports flags and passwords properties
# ---------------------------------------------------------------------------
response=$(send_cmd ACL GETUSER default)
check "Initial ACL GETUSER default -> flags [nopass], passwords []" "$response" \
    "$(expect_getuser)"

response=$(send_cmd acl getuser default)
check "ACL GETUSER is case-insensitive" "$response" "$(expect_getuser)"

response=$(send_commands 3 ACL GETUSER default 2 ACL WHOAMI 1 PING)
check "Nested GETUSER array followed by more commands on the same connection" "$response" \
    "$(expect_concat "$(expect_getuser)" "$(expect_bulk default)" "$(expect_pong)")"

# ---------------------------------------------------------------------------
# Invalid ACL and raw protocol cases while the default user still has nopass
# ---------------------------------------------------------------------------
for command_case in \
    "ACL" \
    "ACL WHOAMI extra" \
    "ACL GETUSER" \
    "ACL GETUSER default extra" \
    "ACL SETUSER" \
    "ACL SETUSER default" \
    "ACL SETUSER default bad-rule" \
    "ACL UNKNOWN default"; do
    response=$(send_cmd $command_case)
    check_error "Invalid $command_case returns an error" "$response"
done

response=$(send_cmd ACL GETUSER missing-user)
check_error_or_null "ACL GETUSER missing-user returns an error or null bulk" "$response"

response=$(send_raw_bytes '')
check_error_or_no_response "Empty TCP payload produces no success response" "$response"

response=$(send_raw_bytes '*0\r\n')
check_error_or_no_response "Empty RESP array is rejected or ignored" "$response"

response=$(send_raw_bytes '*1\r\n$4\r\nPIN\r\n')
check_error_or_no_response "Malformed bulk length is rejected or times out cleanly" "$response"

response=$(send_raw_bytes 'garbage\r\n')
check_error_or_no_response "Inline garbage is rejected or ignored" "$response"

# ---------------------------------------------------------------------------
# Test 5: ACL SETUSER default >password stores SHA-256 and removes nopass
# ---------------------------------------------------------------------------
PASSWORD_ONE="mypassword"
HASH_ONE=$(sha256_hex "$PASSWORD_ONE")

response=$(send_commands 4 ACL SETUSER default ">$PASSWORD_ONE" 2 ACL WHOAMI)
check "SETUSER password keeps the existing connection authenticated" "$response" \
    "$(expect_concat "$(expect_ok)" "$(expect_bulk default)")"

response=$(send_cmd ACL WHOAMI)
check_prefix "New connection after SETUSER cannot run ACL WHOAMI" "$response" "-NOAUTH"

response=$(send_cmd PING)
check_prefix "New connection after SETUSER cannot run PING" "$response" "-NOAUTH"

response=$(send_commands 3 AUTH default "$PASSWORD_ONE" 3 ACL GETUSER default)
check "AUTH then GETUSER shows first SHA-256 password and no nopass flag" "$response" \
    "$(expect_concat "$(expect_ok)" "$(expect_getuser "$HASH_ONE")")"

# ---------------------------------------------------------------------------
# Test 6: AUTH success and failure cases
# ---------------------------------------------------------------------------
for wrong_password in "wrongpassword" "MYpassword" "mypassword " "" "not-$PASSWORD_ONE"; do
    response=$(send_cmd AUTH default "$wrong_password")
    check_prefix "AUTH default '$wrong_password' -> WRONGPASS" "$response" "$(expect_wrongpass)"
done

for bad_auth_case in \
    "AUTH" \
    "AUTH default" \
    "AUTH default $PASSWORD_ONE extra"; do
    response=$(send_cmd $bad_auth_case)
    check_error "Invalid $bad_auth_case returns an error" "$response"
done

response=$(send_cmd AUTH unknown-user "$PASSWORD_ONE")
check_prefix "AUTH unknown-user -> WRONGPASS" "$response" "$(expect_wrongpass)"

response=$(send_cmd AUTH DEFAULT "$PASSWORD_ONE")
check_prefix "AUTH username is not accidentally treated as case-insensitive" "$response" "$(expect_wrongpass)"

response=$(send_cmd auth default "$PASSWORD_ONE")
check "AUTH command name is case-insensitive" "$response" "$(expect_ok)"

# ---------------------------------------------------------------------------
# Test 7-8: Enforce authentication, then persist authentication after AUTH
# ---------------------------------------------------------------------------
for unauth_case in \
    "PING" \
    "ECHO hello" \
    "SET locked-key locked-value" \
    "GET locked-key" \
    "INCR locked-counter" \
    "TYPE locked-key" \
    "MULTI" \
    "ACL WHOAMI" \
    "ACL GETUSER default" \
    "ACL SETUSER default >blocked" \
    "UNKNOWNCMD"; do
    response=$(send_cmd $unauth_case)
    check_prefix "Unauthenticated $unauth_case -> NOAUTH" "$response" "-NOAUTH"
done

response=$(send_commands 3 AUTH default "$PASSWORD_ONE" 1 PING 2 ACL WHOAMI)
check "AUTH unlocks PING and WHOAMI on the same connection" "$response" \
    "$(expect_concat "$(expect_ok)" "$(expect_pong)" "$(expect_bulk default)")"

response=$(send_commands 3 AUTH default "$PASSWORD_ONE" 3 SET locked-key unlocked-value)
check "AUTH unlocks SET on the same connection" "$response" \
    "$(expect_concat "$(expect_ok)" "$(expect_ok)")"

response=$(send_commands 3 AUTH default "$PASSWORD_ONE" 2 GET locked-key)
check "AUTH unlocks GET on the same connection" "$response" \
    "$(expect_concat "$(expect_ok)" "$(expect_bulk unlocked-value)")"

response=$(send_commands 3 AUTH default "$PASSWORD_ONE" 3 ACL GETUSER default)
check "AUTH unlocks ACL GETUSER on the same connection" "$response" \
    "$(expect_concat "$(expect_ok)" "$(expect_getuser "$HASH_ONE")")"

response=$(send_cmd GET locked-key)
check_prefix "A separate new connection is still unauthenticated after another client AUTHs" "$response" "-NOAUTH"

# ---------------------------------------------------------------------------
# More complicated password state: multiple, special, and empty passwords
# ---------------------------------------------------------------------------
PASSWORD_TWO="newpassword"
PASSWORD_THREE='pa ss:word|!@#[]'
PASSWORD_EMPTY=""
HASH_TWO=$(sha256_hex "$PASSWORD_TWO")
HASH_THREE=$(sha256_hex "$PASSWORD_THREE")
HASH_EMPTY=$(sha256_hex "$PASSWORD_EMPTY")

response=$(send_commands \
    3 AUTH default "$PASSWORD_ONE" \
    4 ACL SETUSER default ">$PASSWORD_TWO" \
    3 ACL GETUSER default)
check "SETUSER appends a second password hash" "$response" \
    "$(expect_concat "$(expect_ok)" "$(expect_ok)" "$(expect_getuser "$HASH_ONE" "$HASH_TWO")")"

response=$(send_commands \
    3 AUTH default "$PASSWORD_TWO" \
    4 ACL SETUSER default ">$PASSWORD_THREE" \
    3 ACL GETUSER default)
check "SETUSER accepts a password containing spaces and punctuation" "$response" \
    "$(expect_concat "$(expect_ok)" "$(expect_ok)" "$(expect_getuser "$HASH_ONE" "$HASH_TWO" "$HASH_THREE")")"

response=$(send_commands \
    3 AUTH default "$PASSWORD_THREE" \
    4 ACL SETUSER default ">" \
    3 ACL GETUSER default)
check "SETUSER can add an empty password hash" "$response" \
    "$(expect_concat "$(expect_ok)" "$(expect_ok)" "$(expect_getuser "$HASH_ONE" "$HASH_TWO" "$HASH_THREE" "$HASH_EMPTY")")"

for valid_password in "$PASSWORD_ONE" "$PASSWORD_TWO" "$PASSWORD_THREE" "$PASSWORD_EMPTY"; do
    response=$(send_cmd AUTH default "$valid_password")
    check "AUTH succeeds with stored password '$valid_password'" "$response" "$(expect_ok)"
done

response=$(send_commands \
    3 AUTH default "$PASSWORD_EMPTY" \
    1 PING \
    2 ACL WHOAMI \
    2 GET locked-key)
check "Empty password AUTH authenticates the connection when its hash is stored" "$response" \
    "$(expect_concat "$(expect_ok)" "$(expect_pong)" "$(expect_bulk default)" "$(expect_bulk unlocked-value)")"

response=$(send_cmd AUTH default "not-stored-anywhere")
check_prefix "AUTH with password not in the hash list still fails" "$response" "$(expect_wrongpass)"

# ---------------------------------------------------------------------------
# Transaction and pipelining after AUTH
# ---------------------------------------------------------------------------
response=$(send_commands \
    3 AUTH default "$PASSWORD_TWO" \
    1 MULTI \
    3 SET tx-key tx-value \
    2 GET tx-key \
    1 EXEC)
check_prefix "Authenticated transaction starts with OK and QUEUED replies" "$response" \
    "$(expect_concat "$(expect_ok)" "$(expect_ok)" "$(expect_simple QUEUED)" "$(expect_simple QUEUED)")"

response=$(send_commands \
    3 AUTH default "$PASSWORD_TWO" \
    2 ACL WHOAMI \
    1 PING \
    2 ACL WHOAMI)
check "Authenticated pipeline keeps the authenticated user" "$response" \
    "$(expect_concat \
        "$(expect_ok)" \
        "$(expect_bulk default)" \
        "$(expect_pong)" \
        "$(expect_bulk default)")"

# ---------------------------------------------------------------------------
# Final raw protocol checks after auth is required
# ---------------------------------------------------------------------------
response=$(send_raw_bytes '*1\r\n$4\r\nAUTH\r\n')
check_error "Raw AUTH with missing args returns an error" "$response"

response=$(send_raw_bytes '*3\r\n$4\r\nAUTH\r\n$7\r\ndefault\r\n$10\r\nmypassword\r\n')
check "Raw AUTH default mypassword succeeds" "$response" "$(expect_ok)"

response=$(send_raw_bytes '*2\r\n$3\r\nACL\r\n$6\r\nWHOAMI\r\n')
check_prefix "Raw unauthenticated ACL WHOAMI is blocked" "$response" "-NOAUTH"

cleanup
trap - EXIT

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "ACL/AUTH tests passed."
else
    exit 1
fi
