#!/bin/bash
# Verify AOF config defaults/flags, startup file creation, command logging, filtering, and replay.

source "$(dirname "$0")/helpers.sh"

echo "=== AOF persistence: config, files, write filtering, and replay ==="

if [ "${EXTERNAL_SERVER:-0}" = "1" ]; then
    fail "EXTERNAL_SERVER=1 is not supported by this script because it restarts the server with many AOF fixtures."
    exit 1
fi

build_server

PASS_COUNT=0
FAIL_COUNT=0
TMPDIR_LOCAL=$(mktemp -d)
SERVER_LOG="$TMPDIR_LOCAL/server.log"

echo "TMPDIR_LOCAL = $TMPDIR_LOCAL"

cleanup() {
    stop_server
    rm -rf "$TMPDIR_LOCAL"
}
trap cleanup EXIT

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
    timeout 6 nc -q 1 -W 3 127.0.0.1 6379 < "$tmp" 2>/dev/null
    rm -f "$tmp"
}

send_raw_file() {
    local file="$1"
    timeout 6 nc -q 1 -w 3 127.0.0.1 6379 < "$file" 2>/dev/null
}

wait_for_port() {
    local i
    for i in $(seq 1 50); do
        nc -z 127.0.0.1 6379 >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 1
}

start_server_with_args() {
    local label="$1"
    shift

    stop_server
    fuser -k 6379/tcp >/dev/null 2>&1 || true
    sleep 0.2

    (
        cd "$REPO_ROOT" || exit 1
        exec "$BINARY" "$@"
    ) > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!

    if wait_for_port && kill -0 "$SERVER_PID" 2>/dev/null; then
        info "Started server for $label (PID $SERVER_PID)"
        return 0
    fi

    fail "Server failed to start for $label"
    fail "  args: $*"
    fail "  log:"
    sed 's/^/    /' "$SERVER_LOG"
    FAIL_COUNT=$((FAIL_COUNT + 1))
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

check_file_exists() {
    local label="$1" path="$2"
    if [ -e "$path" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  missing: $path"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_file_absent() {
    local label="$1" path="$2"
    if [ ! -e "$path" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected absent: $path"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_empty_file() {
    local label="$1" path="$2"
    if [ -f "$path" ] && [ ! -s "$path" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected empty file: $path"
        [ -e "$path" ] && fail "  size: $(wc -c < "$path")"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_file_text() {
    local label="$1" path="$2" expected="$3"
    if [ -f "$path" ] && [ "$(cat "$path")" = "$expected" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected : $(printf '%s' "$expected" | cat -A)"
        if [ -f "$path" ]; then
            fail "  got      : $(cat "$path" | cat -A)"
        else
            fail "  file missing: $path"
        fi
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

expect_ok()          { printf '+OK\r'; }
expect_int()         { printf ':%d\r' "$1"; }
expect_bulk()        { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_null()        { printf '$-1\r'; }
expect_simple()      { printf '+%s\r' "$1"; }
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

repeat_char() {
    local char="$1" count="$2"
    printf "%${count}s" "" | tr ' ' "$char"
}

make_aof_fixture() {
    local dir="$1" appenddirname="$2" appendfilename="$3" activefile="$4" payloadfile="$5"
    local aof_dir="$dir/$appenddirname"
    mkdir -p "$aof_dir"
    printf 'file %s seq 1 type i\n' "$activefile" > "$aof_dir/$appendfilename.manifest"
    if [ -n "$payloadfile" ]; then
        cp "$payloadfile" "$aof_dir/$activefile"
    else
        : > "$aof_dir/$activefile"
    fi
}

write_resp_file() {
    local outfile="$1"
    shift
    : > "$outfile"
    while [ "$#" -gt 0 ]; do
        local argc="$1"
        shift
        {
            printf '*%d\r\n' "$argc"
            local i
            for i in $(seq 1 "$argc"); do
                printf '$%d\r\n%s\r\n' "${#1}" "$1"
                shift
            done
        } >> "$outfile"
    done
}

check_aof_commands() {
    local label="$1" file="$2"
    shift 2

    python3 - "$file" "$@" <<'PY'
import json
import sys

path = sys.argv[1]
expected = [json.loads(arg) for arg in sys.argv[2:]]
data = open(path, "rb").read()
pos = 0
commands = []

def read_line():
    global pos
    end = data.find(b"\r\n", pos)
    if end == -1:
        raise ValueError(f"missing CRLF at byte {pos}")
    line = data[pos:end]
    pos = end + 2
    return line

while pos < len(data):
    header = read_line()
    if not header.startswith(b"*"):
        raise ValueError(f"expected array at byte {pos}, got {header!r}")
    argc = int(header[1:])
    command = []
    for _ in range(argc):
        bulk = read_line()
        if not bulk.startswith(b"$"):
            raise ValueError(f"expected bulk string at byte {pos}, got {bulk!r}")
        length = int(bulk[1:])
        if length < 0:
            raise ValueError("null bulk string is invalid inside command")
        value = data[pos:pos + length]
        if len(value) != length:
            raise ValueError("truncated bulk payload")
        pos += length
        if data[pos:pos + 2] != b"\r\n":
            raise ValueError(f"bulk string missing trailing CRLF at byte {pos}")
        pos += 2
        command.append(value.decode("latin1"))
    commands.append(command)

if commands != expected:
    print("expected:", expected, file=sys.stderr)
    print("got     :", commands, file=sys.stderr)
    print("raw hex :", data.hex(), file=sys.stderr)
    sys.exit(1)
PY

    if [ $? -eq 0 ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  AOF file: $file"
        [ -f "$file" ] && fail "  raw bytes: $(cat "$file" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# ---------------------------------------------------------------------------
# Test 1: Default AOF config values are visible through CONFIG GET
# ---------------------------------------------------------------------------
if start_server_with_args "default AOF config"; then
    response=$(send_cmd CONFIG GET dir)
    check "CONFIG GET dir returns startup working directory" "$response" "$(expect_array dir "$REPO_ROOT")"

    response=$(send_cmd CONFIG GET appendonly)
    check "CONFIG GET appendonly default is no" "$response" "$(expect_array appendonly no)"

    response=$(send_cmd CONFIG GET appenddirname)
    check "CONFIG GET appenddirname default is appendonlydir" "$response" "$(expect_array appenddirname appendonlydir)"

    response=$(send_cmd CONFIG GET appendfilename)
    check "CONFIG GET appendfilename default is appendonly.aof" "$response" "$(expect_array appendfilename appendonly.aof)"

    response=$(send_cmd CONFIG GET appendfsync)
    check "CONFIG GET appendfsync default is everysec" "$response" "$(expect_array appendfsync everysec)"
fi

# ---------------------------------------------------------------------------
# Test 2: Flags override some or all AOF options while omitted options default
# ---------------------------------------------------------------------------
FLAGS_DIR="$TMPDIR_LOCAL/flags dir with spaces"
mkdir -p "$FLAGS_DIR"
if start_server_with_args "AOF flags override all options" \
    --dir "$FLAGS_DIR" \
    --appendonly yes \
    --appenddirname "custom-aof-dir" \
    --appendfilename "custom-base.aof" \
    --appendfsync always; then
    response=$(send_cmd CONFIG GET dir)
    check "CONFIG GET dir returns --dir value" "$response" "$(expect_array dir "$FLAGS_DIR")"

    response=$(send_cmd CONFIG GET appendonly)
    check "CONFIG GET appendonly returns yes from flag" "$response" "$(expect_array appendonly yes)"

    response=$(send_cmd CONFIG GET appenddirname)
    check "CONFIG GET appenddirname returns flag value" "$response" "$(expect_array appenddirname custom-aof-dir)"

    response=$(send_cmd CONFIG GET appendfilename)
    check "CONFIG GET appendfilename returns flag value" "$response" "$(expect_array appendfilename custom-base.aof)"

    response=$(send_cmd CONFIG GET appendfsync)
    check "CONFIG GET appendfsync returns flag value" "$response" "$(expect_array appendfsync always)"
fi

PARTIAL_DIR="$TMPDIR_LOCAL/partial-flags"
mkdir -p "$PARTIAL_DIR"
if start_server_with_args "AOF partial flags keep defaults" --dir "$PARTIAL_DIR" --appendonly yes; then
    response=$(send_cmd CONFIG GET appenddirname)
    check "Partial flags keep default appenddirname" "$response" "$(expect_array appenddirname appendonlydir)"

    response=$(send_cmd CONFIG GET appendfilename)
    check "Partial flags keep default appendfilename" "$response" "$(expect_array appendfilename appendonly.aof)"

    response=$(send_cmd CONFIG GET appendfsync)
    check "Partial flags keep default appendfsync" "$response" "$(expect_array appendfsync everysec)"
fi

# ---------------------------------------------------------------------------
# Test 3-5: AOF directory, first incremental file, and manifest creation
# ---------------------------------------------------------------------------
NO_AOF_DIR="$TMPDIR_LOCAL/no-aof"
mkdir -p "$NO_AOF_DIR"
if start_server_with_args "appendonly no skips directory creation" \
    --dir "$NO_AOF_DIR" \
    --appendonly no \
    --appenddirname "should-not-exist"; then
    sleep 0.2
    check_file_absent "appendonly no does not create appenddirname" "$NO_AOF_DIR/should-not-exist"
fi

CREATE_DIR="$TMPDIR_LOCAL/create-aof"
mkdir -p "$CREATE_DIR"
if start_server_with_args "appendonly yes creates files" \
    --dir "$CREATE_DIR" \
    --appendonly yes \
    --appenddirname "append space dir" \
    --appendfilename "primary.aof"; then
    AOF_DIR="$CREATE_DIR/append space dir"
    AOF_FILE="$AOF_DIR/primary.aof.1.incr.aof"
    MANIFEST="$AOF_DIR/primary.aof.manifest"

    check_file_exists "appendonly yes creates append-only directory" "$AOF_DIR"
    check_empty_file "startup creates empty first incremental AOF file" "$AOF_FILE"
    check_file_exists "startup creates manifest file" "$MANIFEST"
    check_file_text "manifest contains exact first incremental entry" "$MANIFEST" \
        "file primary.aof.1.incr.aof seq 1 type i"
fi

PREEXIST_DIR="$TMPDIR_LOCAL/preexisting"
mkdir -p "$PREEXIST_DIR/pre-dir"
if start_server_with_args "appendonly yes tolerates existing directory" \
    --dir "$PREEXIST_DIR" \
    --appendonly yes \
    --appenddirname "pre-dir" \
    --appendfilename "pre.aof"; then
    check_file_exists "existing appenddirname remains usable" "$PREEXIST_DIR/pre-dir"
    check_file_exists "startup creates files inside existing appenddirname" "$PREEXIST_DIR/pre-dir/pre.aof.1.incr.aof"
fi

# ---------------------------------------------------------------------------
# Test 6: Single command writes use the manifest active file, not the flag name
# ---------------------------------------------------------------------------
SINGLE_DIR="$TMPDIR_LOCAL/single-write"
SINGLE_ACTIVE="random123.1.incr.aof"
make_aof_fixture "$SINGLE_DIR" "appendonlydir" "configured.aof" "$SINGLE_ACTIVE" ""
if start_server_with_args "single manifest-driven write" \
    --dir "$SINGLE_DIR" \
    --appendonly yes \
    --appenddirname appendonlydir \
    --appendfilename configured.aof \
    --appendfsync always; then
    response=$(send_cmd SET "space key" "value with spaces")
    check "SET with spaces succeeds before AOF check" "$response" "$(expect_ok)"

    check_aof_commands "single SET is appended to manifest active file" \
        "$SINGLE_DIR/appendonlydir/$SINGLE_ACTIVE" \
        '["SET","space key","value with spaces"]'

    check_file_absent "single write does not create hardcoded configured.aof.1.incr.aof" \
        "$SINGLE_DIR/appendonlydir/configured.aof.1.incr.aof"
fi

# ---------------------------------------------------------------------------
# Test 7-8: Multiple writes, mixed command types, large values, and read filtering
# ---------------------------------------------------------------------------
MIX_DIR="$TMPDIR_LOCAL/mixed-write"
MIX_ACTIVE="wild.name.with.dots.1.incr.aof"
make_aof_fixture "$MIX_DIR" "aof-mix-dir" "server-base.aof" "$MIX_ACTIVE" ""
LARGE_VALUE=$(repeat_char Z 4096)
if start_server_with_args "mixed write filtering" \
    --dir "$MIX_DIR" \
    --appendonly yes \
    --appenddirname aof-mix-dir \
    --appendfilename server-base.aof \
    --appendfsync always; then
    response=$(send_cmd SET alpha 1)
    check "SET alpha logs as write" "$response" "$(expect_ok)"

    response=$(send_cmd GET alpha)
    check "GET alpha is served but should not be logged" "$response" "$(expect_bulk 1)"

    response=$(send_cmd PING)
    check "PING is served but should not be logged" "$response" "$(expect_simple PONG)"

    response=$(send_cmd ECHO "do-not-log")
    check "ECHO is served but should not be logged" "$response" "$(expect_bulk do-not-log)"

    response=$(send_cmd CONFIG GET appendonly)
    check "CONFIG GET is served but should not be logged" "$response" "$(expect_array appendonly yes)"

    response=$(send_cmd INCR counter)
    check "INCR missing counter logs as write" "$response" "$(expect_int 1)"

    response=$(send_cmd SET empty-value "")
    check "SET empty string logs with zero-length bulk" "$response" "$(expect_ok)"

    response=$(send_cmd SET big "$LARGE_VALUE")
    check "SET large value logs with full bulk length" "$response" "$(expect_ok)"

    response=$(send_cmd RPUSH list one two three)
    check "RPUSH multi-value logs as write" "$response" "$(expect_int 3)"

    response=$(send_cmd LPUSH list zero)
    check "LPUSH logs as write" "$response" "$(expect_int 4)"

    response=$(send_cmd LPOP list 2)
    check "LPOP count logs as write" "$response" "$(expect_array zero one)"

    response=$(send_cmd TYPE list)
    check "TYPE is served but should not be logged" "$response" "$(expect_simple list)"

    response=$(send_cmd SET after-read-filter ok)
    check "Final SET after reads logs in order" "$response" "$(expect_ok)"

    check_aof_commands "AOF contains only writes in exact order across command types" \
        "$MIX_DIR/aof-mix-dir/$MIX_ACTIVE" \
        '["SET","alpha","1"]' \
        '["INCR","counter"]' \
        '["SET","empty-value",""]' \
        "[\"SET\",\"big\",\"$LARGE_VALUE\"]" \
        '["RPUSH","list","one","two","three"]' \
        '["LPUSH","list","zero"]' \
        '["LPOP","list","2"]' \
        '["SET","after-read-filter","ok"]'
fi

# ---------------------------------------------------------------------------
# Test 9: Replay a single manifest-selected command
# ---------------------------------------------------------------------------
REPLAY_SINGLE_DIR="$TMPDIR_LOCAL/replay-single"
REPLAY_SINGLE_PAYLOAD="$TMPDIR_LOCAL/replay-single.resp"
write_resp_file "$REPLAY_SINGLE_PAYLOAD" \
    3 SET restored-key restored-value
make_aof_fixture "$REPLAY_SINGLE_DIR" "appendonlydir" "visible-name.aof" "not-the-default.1.incr.aof" "$REPLAY_SINGLE_PAYLOAD"
if start_server_with_args "single command replay" \
    --dir "$REPLAY_SINGLE_DIR" \
    --appendonly yes \
    --appenddirname appendonlydir \
    --appendfilename visible-name.aof; then
    response=$(send_cmd GET restored-key)
    check "GET sees key restored from manifest-selected AOF file" "$response" "$(expect_bulk restored-value)"

    response=$(send_cmd GET missing-after-single-replay)
    check "Missing key remains null after replay" "$response" "$(expect_null)"
fi

# ---------------------------------------------------------------------------
# Test 10: Replay many commands until EOF, including overwrites and list changes
# ---------------------------------------------------------------------------
REPLAY_MULTI_DIR="$TMPDIR_LOCAL/replay-multi"
REPLAY_MULTI_PAYLOAD="$TMPDIR_LOCAL/replay-multi.resp"
write_resp_file "$REPLAY_MULTI_PAYLOAD" \
    3 SET replay-a one \
    3 SET replay-b two \
    2 INCR replay-counter \
    2 INCR replay-counter \
    4 RPUSH replay-list right1 right2 \
    3 LPUSH replay-list left1 \
    3 SET replay-a overwritten \
    3 LPOP replay-list 2 \
    5 SET expiring-key gone PX 1
make_aof_fixture "$REPLAY_MULTI_DIR" "deep-aof-dir" "multi-base.aof" "deep-random.1.incr.aof" "$REPLAY_MULTI_PAYLOAD"
if start_server_with_args "multiple command replay" \
    --dir "$REPLAY_MULTI_DIR" \
    --appendonly yes \
    --appenddirname deep-aof-dir \
    --appendfilename multi-base.aof; then
    response=$(send_cmd GET replay-a)
    check "Replay applies later SET overwrite" "$response" "$(expect_bulk overwritten)"

    response=$(send_cmd GET replay-b)
    check "Replay restores independent key" "$response" "$(expect_bulk two)"

    response=$(send_cmd GET replay-counter)
    check "Replay runs both INCR commands" "$response" "$(expect_bulk 2)"

    response=$(send_cmd LPOP replay-list)
    check "Replay applied LPUSH/RPUSH/LPOP sequence and left right2" "$response" "$(expect_bulk right2)"

    sleep 0.02
    response=$(send_cmd GET expiring-key)
    check "Replay preserves SET PX expiry semantics" "$response" "$(expect_null)"
fi

# ---------------------------------------------------------------------------
# Extra malformed/empty AOF fixtures: startup should stay usable
# ---------------------------------------------------------------------------
EMPTY_REPLAY_DIR="$TMPDIR_LOCAL/replay-empty"
make_aof_fixture "$EMPTY_REPLAY_DIR" "empty-aof-dir" "empty-base.aof" "empty-active.1.incr.aof" ""
if start_server_with_args "empty AOF replay" \
    --dir "$EMPTY_REPLAY_DIR" \
    --appendonly yes \
    --appenddirname empty-aof-dir \
    --appendfilename empty-base.aof; then
    response=$(send_cmd GET anything)
    check "Empty AOF starts with empty database" "$response" "$(expect_null)"
fi

MALFORMED_REPLAY_DIR="$TMPDIR_LOCAL/replay-malformed"
MALFORMED_PAYLOAD="$TMPDIR_LOCAL/replay-malformed.resp"
{
    write_resp_command SET before-malformed ok
    printf '*2\r\n$3\r\nSET\r\n$20\r\ntruncated'
} > "$MALFORMED_PAYLOAD"
make_aof_fixture "$MALFORMED_REPLAY_DIR" "bad-aof-dir" "bad-base.aof" "bad-active.1.incr.aof" "$MALFORMED_PAYLOAD"
if start_server_with_args "malformed AOF replay stops at bad command" \
    --dir "$MALFORMED_REPLAY_DIR" \
    --appendonly yes \
    --appenddirname bad-aof-dir \
    --appendfilename bad-base.aof; then
    response=$(send_cmd GET before-malformed)
    check "Malformed AOF keeps valid commands before malformed tail" "$response" "$(expect_bulk ok)"

    response=$(send_cmd SET still-usable yes)
    check "Server remains usable after malformed AOF tail" "$response" "$(expect_ok)"
fi

# ---------------------------------------------------------------------------
# Extra parser stress: pipelined writes over one connection are all logged
# ---------------------------------------------------------------------------
PIPE_DIR="$TMPDIR_LOCAL/pipelined-write"
PIPE_ACTIVE="pipeline-active.1.incr.aof"
PIPE_REQ="$TMPDIR_LOCAL/pipeline-requests.resp"
make_aof_fixture "$PIPE_DIR" "pipe-aof-dir" "pipe-base.aof" "$PIPE_ACTIVE" ""
write_resp_file "$PIPE_REQ" \
    3 SET pipe-a A \
    3 SET pipe-b B \
    2 INCR pipe-i \
    2 GET pipe-a \
    3 SET pipe-c C
if start_server_with_args "pipelined writes are logged in order" \
    --dir "$PIPE_DIR" \
    --appendonly yes \
    --appenddirname pipe-aof-dir \
    --appendfilename pipe-base.aof \
    --appendfsync always; then
    response=$(send_raw_file "$PIPE_REQ")
    case "$response" in
        *"+OK"*":1"*"\$1"*"A"* )
            pass "Pipelined request receives combined responses"
            PASS_COUNT=$((PASS_COUNT + 1))
            ;;
        *)
            fail "Pipelined request receives combined responses"
            fail "  got: $(printf '%s' "$response" | cat -A)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            ;;
    esac

    check_aof_commands "Pipelined AOF excludes interleaved GET and preserves write order" \
        "$PIPE_DIR/pipe-aof-dir/$PIPE_ACTIVE" \
        '["SET","pipe-a","A"]' \
        '["SET","pipe-b","B"]' \
        '["INCR","pipe-i"]' \
        '["SET","pipe-c","C"]'
fi

stop_server

echo "=============================="
echo "AOF persistence tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi
