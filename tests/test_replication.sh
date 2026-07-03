#!/bin/bash
# Replication stages: custom ports, INFO replication, replica role, and handshakes.
#
# This script is intentionally broader than the CodeCrafters stage checks. It
# includes invalid/empty inputs and timing-sensitive handshake checks so you can
# run it manually while implementing the replication stages.

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPLICATION_TEST_LOG="${REPLICATION_TEST_LOG:-$TESTS_DIR/test_replication_output.log}"
: > "$REPLICATION_TEST_LOG"
exec > >(tee -a "$REPLICATION_TEST_LOG") 2>&1

source "$TESTS_DIR/helpers.sh"
trap - EXIT

echo "=== Replication: port, INFO, replica role, and handshake tests ==="
info "Writing a copy of this test output to $REPLICATION_TEST_LOG"

if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 is required for this test script"
    exit 1
fi

if ! command -v nc >/dev/null 2>&1; then
    fail "nc is required for this test script"
    exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TMPDIR_LOCAL=$(mktemp -d)
SERVER_PIDS=()
FAKE_MASTER_PIDS=()
LAST_SERVER_PID=""
LAST_FAKE_MASTER_PID=""

cleanup() {
    local pid

    for pid in "${SERVER_PIDS[@]}" "${FAKE_MASTER_PIDS[@]}"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
        fi
    done

    rm -rf "$TMPDIR_LOCAL"
}

trap cleanup EXIT

record_pass() {
    pass "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

record_fail() {
    fail "$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

record_skip() {
    info "SKIP: $1"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

show_bytes() {
    printf '%s' "$1" | cat -A
}

check_equals() {
    local label="$1" actual="$2" expected="$3"

    if [ "$actual" = "$expected" ]; then
        record_pass "$label"
    else
        record_fail "$label"
        fail "  expected : $(show_bytes "$expected")"
        fail "  got      : $(show_bytes "$actual")"
    fi
}

check_contains() {
    local label="$1" actual="$2" needle="$3"

    if [[ "$actual" == *"$needle"* ]]; then
        record_pass "$label"
    else
        record_fail "$label"
        fail "  expected response to contain: $needle"
        fail "  got: $(show_bytes "$actual")"
    fi
}

check_not_contains() {
    local label="$1" actual="$2" needle="$3"

    if [[ "$actual" != *"$needle"* ]]; then
        record_pass "$label"
    else
        record_fail "$label"
        fail "  response unexpectedly contained: $needle"
        fail "  got: $(show_bytes "$actual")"
    fi
}

check_regex() {
    local label="$1" actual="$2" regex="$3"

    if [[ "$actual" =~ $regex ]]; then
        record_pass "$label"
    else
        record_fail "$label"
        fail "  expected response to match regex: $regex"
        fail "  got: $(show_bytes "$actual")"
    fi
}

check_starts_with() {
    local label="$1" actual="$2" prefix="$3"

    if [[ "$actual" == "$prefix"* ]]; then
        record_pass "$label"
    else
        record_fail "$label"
        fail "  expected prefix: $(show_bytes "$prefix")"
        fail "  got            : $(show_bytes "$actual")"
    fi
}

check_resp_reply() {
    local label="$1" response="$2"

    case "$response" in
        +*|-*|:*|\$*|\**)
            record_pass "$label"
            ;;
        *)
            record_fail "$label"
            fail "  expected a RESP reply, got: $(show_bytes "$response")"
            ;;
    esac
}

check_file_contains_line() {
    local label="$1" file="$2" line="$3"

    if grep -Fxq "$line" "$file" 2>/dev/null; then
        record_pass "$label"
    else
        record_fail "$label"
        fail "  missing line: $line"
        fail "  file contents:"
        sed 's/^/    /' "$file" 2>/dev/null || true
    fi
}

check_file_not_contains() {
    local label="$1" file="$2" pattern="$3"

    if grep -Fq "$pattern" "$file" 2>/dev/null; then
        record_fail "$label"
        fail "  unexpected pattern: $pattern"
        fail "  file contents:"
        sed 's/^/    /' "$file" 2>/dev/null || true
    else
        record_pass "$label"
    fi
}

write_resp_command() {
    printf '*%d\r\n' "$#"
    local word
    for word in "$@"; do
        printf '$%d\r\n%s\r\n' "${#word}" "$word"
    done
}

send_cmd() {
    local port="$1"
    shift

    local tmp
    tmp=$(mktemp "$TMPDIR_LOCAL/resp.XXXXXX")
    write_resp_command "$@" > "$tmp"
    timeout 4 nc -q 1 -W 1 127.0.0.1 "$port" < "$tmp" 2>/dev/null
    local status=$?
    rm -f "$tmp"
    return "$status"
}

send_raw() {
    local port="$1" raw="$2"
    printf '%b' "$raw" | timeout 4 nc -q 1 -W 1 127.0.0.1 "$port" 2>/dev/null
}

get_free_port() {
    python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
}

wait_for_port() {
    local port="$1" attempts="${2:-60}" i

    for i in $(seq 1 "$attempts"); do
        if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done

    return 1
}

stop_process() {
    local pid="$1"

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    fi
}

start_redis() {
    local wait_port="$1" log_file="$2"
    shift 2

    "$BINARY" "$@" > "$log_file" 2>&1 &
    LAST_SERVER_PID=$!
    SERVER_PIDS+=("$LAST_SERVER_PID")

    if [ -n "$wait_port" ]; then
        if ! wait_for_port "$wait_port"; then
            record_fail "Server started and listened on port $wait_port"
            fail "  server log:"
            sed 's/^/    /' "$log_file" 2>/dev/null || true
            return 1
        fi
    fi

    return 0
}

start_fake_master() {
    local port="$1" capture_file="$2"

    python3 - "$port" "$capture_file" <<'PY' &
import select
import socket
import sys
import time

port = int(sys.argv[1])
capture_file = sys.argv[2]
repl_id = "8371b4fb1155b71f4a04d3e1bc3e18c4a990aeeb"

def emit(line):
    with open(capture_file, "a", encoding="utf-8") as f:
        f.write(line + "\n")
        f.flush()

def read_line(conn):
    data = bytearray()
    while not data.endswith(b"\r\n"):
        chunk = conn.recv(1)
        if not chunk:
            raise EOFError("connection closed while reading line")
        data.extend(chunk)
    return bytes(data)

def read_resp_array(conn):
    raw = bytearray()
    first = read_line(conn)
    raw.extend(first)
    if not first.startswith(b"*"):
        raise ValueError("expected RESP array, got %r" % first)

    count = int(first[1:-2])
    values = []
    for _ in range(count):
        header = read_line(conn)
        raw.extend(header)
        if not header.startswith(b"$"):
            raise ValueError("expected bulk string, got %r" % header)

        size = int(header[1:-2])
        payload = bytearray()
        while len(payload) < size + 2:
            chunk = conn.recv(size + 2 - len(payload))
            if not chunk:
                raise EOFError("connection closed while reading bulk string")
            payload.extend(chunk)

        raw.extend(payload)
        if not payload.endswith(b"\r\n"):
            raise ValueError("bulk string missing CRLF")
        values.append(bytes(payload[:-2]).decode("utf-8", "replace"))

    return values, bytes(raw)

def check_early(conn, step_name):
    readable, _, _ = select.select([conn], [], [], 0.25)
    if readable:
        emit("EARLY_BEFORE_%s yes" % step_name)
    else:
        emit("EARLY_BEFORE_%s no" % step_name)

responses = [
    ("PONG", b"+PONG\r\n"),
    ("REPLCONF_PORT_OK", b"+OK\r\n"),
    ("REPLCONF_CAPA_OK", b"+OK\r\n"),
    ("FULLRESYNC", ("+FULLRESYNC %s 0\r\n" % repl_id).encode("ascii")),
]

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", port))
    server.listen(1)
    server.settimeout(8)
    emit("LISTENING %d" % port)

    try:
        conn, addr = server.accept()
    except socket.timeout:
        emit("ERROR accept timeout")
        sys.exit(2)

    with conn:
        emit("CONNECTED %s:%d" % addr)
        conn.settimeout(8)
        for idx, (step_name, response) in enumerate(responses, start=1):
            try:
                values, raw = read_resp_array(conn)
            except Exception as exc:
                emit("ERROR read command %d: %s" % (idx, exc))
                sys.exit(3)

            emit("CMD %d %s" % (idx, " ".join(values)))
            emit("HEX %d %s" % (idx, raw.hex()))

            if idx < len(responses):
                check_early(conn, step_name)

            time.sleep(0.05)
            conn.sendall(response)

        emit("DONE")
PY
    LAST_FAKE_MASTER_PID=$!
    FAKE_MASTER_PIDS+=("$LAST_FAKE_MASTER_PID")

    for _ in $(seq 1 60); do
        if grep -Fxq "LISTENING $port" "$capture_file" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$LAST_FAKE_MASTER_PID" 2>/dev/null; then
            record_fail "Fake master started on port $port"
            sed 's/^/    /' "$capture_file" 2>/dev/null || true
            return 1
        fi
        sleep 0.1
    done

    record_fail "Fake master started on port $port"
    fail "  timed out waiting for fake master to listen"
    return 1
}

run_master_handshake_client() {
    local port="$1" replica_port="$2" output_file="$3"

    python3 - "$port" "$replica_port" "$output_file" <<'PY'
import re
import socket
import sys

port = int(sys.argv[1])
replica_port = sys.argv[2]
output_file = sys.argv[3]

def resp_array(*args):
    out = bytearray()
    out.extend(("*%d\r\n" % len(args)).encode("ascii"))
    for arg in args:
        data = str(arg).encode("utf-8")
        out.extend(("$%d\r\n" % len(data)).encode("ascii"))
        out.extend(data + b"\r\n")
    return bytes(out)

def read_line(sock):
    data = bytearray()
    while not data.endswith(b"\r\n"):
        chunk = sock.recv(1)
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)

lines = []

try:
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.settimeout(5)

        cases = [
            ("PING", resp_array("PING"), b"+PONG\r\n"),
            (
                "REPLCONF listening-port",
                resp_array("REPLCONF", "listening-port", replica_port),
                b"+OK\r\n",
            ),
            (
                "REPLCONF capa psync2",
                resp_array("REPLCONF", "capa", "psync2"),
                b"+OK\r\n",
            ),
        ]

        for label, request, expected in cases:
            sock.sendall(request)
            response = read_line(sock)
            lines.append("%s => %r" % (label, response))
            if response != expected:
                lines.append("ERROR expected %r" % (expected,))
                raise SystemExit(2)

        sock.sendall(resp_array("PSYNC", "?", "-1"))
        response = read_line(sock)
        lines.append("PSYNC ? -1 => %r" % (response,))
        if not re.fullmatch(rb"\+FULLRESYNC [A-Za-z0-9]{40} 0\r\n", response):
            lines.append("ERROR expected FULLRESYNC with 40-character replid and offset 0")
            raise SystemExit(3)

        sock.sendall(resp_array("PING"))
        response = read_line(sock)
        lines.append("PING after PSYNC => %r" % (response,))
        if response != b"+PONG\r\n":
            lines.append("ERROR connection did not stay usable after PSYNC")
            raise SystemExit(4)
except Exception as exc:
    lines.append("ERROR %s" % exc)
    raise
finally:
    with open(output_file, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")
PY
}

assert_info_replication_master() {
    local port="$1" label_prefix="$2" response

    response=$(send_cmd "$port" INFO replication)
    check_starts_with "$label_prefix: INFO replication is a bulk string" "$response" '$'
    check_contains "$label_prefix: INFO replication includes role:master" "$response" "role:master"
    check_regex "$label_prefix: INFO replication includes 40-char master_replid" "$response" 'master_replid:[[:alnum:]]{40}'
    check_contains "$label_prefix: INFO replication includes master_repl_offset:0" "$response" "master_repl_offset:0"
    check_not_contains "$label_prefix: master INFO does not report slave role" "$response" "role:slave"
}

assert_info_replication_slave() {
    local port="$1" label_prefix="$2" response

    response=$(send_cmd "$port" INFO replication)
    check_starts_with "$label_prefix: INFO replication is a bulk string" "$response" '$'
    check_contains "$label_prefix: INFO replication includes role:slave" "$response" "role:slave"
    check_contains "$label_prefix: INFO replication includes master_repl_offset:0" "$response" "master_repl_offset:0"
    check_not_contains "$label_prefix: replica INFO does not report master role" "$response" "role:master"
}

build_server

# ---------------------------------------------------------------------------
# 1. Configure listening port
# ---------------------------------------------------------------------------
echo ""
echo "--- Custom port support ---"

if nc -z 127.0.0.1 6379 >/dev/null 2>&1; then
    record_skip "Default port 6379 is already in use; not killing someone else's process"
else
    default_log="$TMPDIR_LOCAL/default_6379.log"
    if start_redis 6379 "$default_log"; then
        default_pid="$LAST_SERVER_PID"
        response=$(send_cmd 6379 PING)
        check_equals "No --port flag defaults to 6379" "$response" "$(printf '+PONG\r')"
        stop_process "$default_pid"
    fi
fi

custom_port=$(get_free_port)
custom_log="$TMPDIR_LOCAL/custom_port.log"
if start_redis "$custom_port" "$custom_log" --port "$custom_port"; then
    custom_pid="$LAST_SERVER_PID"
    response=$(send_cmd "$custom_port" PING)
    check_equals "Server listens on custom --port $custom_port" "$response" "$(printf '+PONG\r')"

    echo_value="port-$custom_port"
    response=$(send_cmd "$custom_port" ECHO "port-$custom_port")
    check_equals "Custom-port server accepts normal commands" "$response" "$(printf '$%d\r\n%s\r' "${#echo_value}" "$echo_value")"

    stop_process "$custom_pid"
fi

port_a=$(get_free_port)
port_b=$(get_free_port)
log_a="$TMPDIR_LOCAL/port_a.log"
log_b="$TMPDIR_LOCAL/port_b.log"
if start_redis "$port_a" "$log_a" --port "$port_a"; then
    pid_a="$LAST_SERVER_PID"
    if start_redis "$port_b" "$log_b" --port "$port_b"; then
        pid_b="$LAST_SERVER_PID"

        response=$(send_cmd "$port_a" SET shared_key from_a)
        check_equals "First custom-port server accepts SET" "$response" "$(printf '+OK\r')"

        response=$(send_cmd "$port_b" GET shared_key)
        check_equals "Second custom-port server has isolated data" "$response" "$(printf '$-1\r')"

        response=$(send_cmd "$port_a" GET shared_key)
        check_equals "First custom-port server keeps its own data" "$response" "$(printf '$6\r\nfrom_a\r')"

        stop_process "$pid_b"
    fi
    stop_process "$pid_a"
fi

# ---------------------------------------------------------------------------
# 2, 3, 4. INFO replication on master and replica
# ---------------------------------------------------------------------------
echo ""
echo "--- INFO replication ---"

master_port=$(get_free_port)
master_info_log="$TMPDIR_LOCAL/master_info.log"
if start_redis "$master_port" "$master_info_log" --port "$master_port"; then
    master_info_pid="$LAST_SERVER_PID"

    assert_info_replication_master "$master_port" "Master"

    response=$(send_cmd "$master_port" info replication)
    check_contains "INFO command is case-insensitive" "$response" "role:master"

    response=$(send_cmd "$master_port" INFO RePlIcAtIoN)
    check_contains "INFO replication section is case-insensitive" "$response" "role:master"

    response=$(send_cmd "$master_port" INFO)
    check_starts_with "INFO with no section returns an error or valid RESP reply" "$response" '-'

    response=$(send_cmd "$master_port" INFO replication extra)
    check_starts_with "INFO replication with extra argument is rejected" "$response" '-'

    response=$(send_cmd "$master_port" INFO "")
    check_resp_reply "INFO with empty section does not crash the server" "$response"

    response=$(send_raw "$master_port" '*0\r\n')
    check_starts_with "Empty RESP array is rejected" "$response" '-'

    response=$(send_raw "$master_port" 'PING\r\n')
    check_starts_with "Inline/non-array PING is rejected" "$response" '-'

    response=$(send_cmd "$master_port" NO_SUCH_COMMAND)
    check_starts_with "Unknown command is rejected" "$response" '-'

    response=$(send_cmd "$master_port" PING)
    check_equals "Server still responds after invalid requests" "$response" "$(printf '+PONG\r')"

    stop_process "$master_info_pid"
fi

fake_master_port=$(get_free_port)
replica_port=$(get_free_port)
fake_capture="$TMPDIR_LOCAL/fake_master_for_info.capture"
replica_info_log="$TMPDIR_LOCAL/replica_info.log"

if start_fake_master "$fake_master_port" "$fake_capture"; then
    if start_redis "$replica_port" "$replica_info_log" --port "$replica_port" --replicaof 127.0.0.1 "$fake_master_port"; then
        replica_info_pid="$LAST_SERVER_PID"
        wait "$LAST_FAKE_MASTER_PID" 2>/dev/null

        assert_info_replication_slave "$replica_port" "Replica with split --replicaof args"
        stop_process "$replica_info_pid"
    fi
fi

quoted_fake_master_port=$(get_free_port)
quoted_replica_port=$(get_free_port)
quoted_capture="$TMPDIR_LOCAL/fake_master_quoted.capture"
quoted_replica_log="$TMPDIR_LOCAL/replica_quoted.log"

if start_fake_master "$quoted_fake_master_port" "$quoted_capture"; then
    if start_redis "$quoted_replica_port" "$quoted_replica_log" --port "$quoted_replica_port" --replicaof "127.0.0.1 $quoted_fake_master_port"; then
        quoted_replica_pid="$LAST_SERVER_PID"
        sleep 0.5

        response=$(send_cmd "$quoted_replica_port" INFO replication)
        check_contains "Replica with quoted --replicaof \"host port\" reports role:slave" "$response" "role:slave"

        stop_process "$quoted_replica_pid"
    fi
    wait "$LAST_FAKE_MASTER_PID" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# 5, 6, 7. Replica sends handshake to master
# ---------------------------------------------------------------------------
echo ""
echo "--- Outbound replica handshake ---"

handshake_master_port=$(get_free_port)
handshake_replica_port=$(get_free_port)
handshake_capture="$TMPDIR_LOCAL/outbound_handshake.capture"
handshake_replica_log="$TMPDIR_LOCAL/outbound_replica.log"

if start_fake_master "$handshake_master_port" "$handshake_capture"; then
    if start_redis "$handshake_replica_port" "$handshake_replica_log" --port "$handshake_replica_port" --replicaof 127.0.0.1 "$handshake_master_port"; then
        handshake_replica_pid="$LAST_SERVER_PID"
        wait "$LAST_FAKE_MASTER_PID" 2>/dev/null

        check_file_contains_line "Replica connects to master" "$handshake_capture" "DONE"
        check_file_contains_line "Handshake step 1 sends PING as RESP array" "$handshake_capture" "CMD 1 PING"
        check_file_contains_line "Handshake step 2 sends REPLCONF listening-port with replica port" "$handshake_capture" "CMD 2 REPLCONF listening-port $handshake_replica_port"
        check_file_contains_line "Handshake step 3 sends REPLCONF capa psync2" "$handshake_capture" "CMD 3 REPLCONF capa psync2"
        check_file_contains_line "Handshake step 4 sends PSYNC ? -1" "$handshake_capture" "CMD 4 PSYNC ? -1"

        check_file_contains_line "Replica waits for PONG before first REPLCONF" "$handshake_capture" "EARLY_BEFORE_PONG no"
        check_file_contains_line "Replica waits for first +OK before second REPLCONF" "$handshake_capture" "EARLY_BEFORE_REPLCONF_PORT_OK no"
        check_file_contains_line "Replica waits for second +OK before PSYNC" "$handshake_capture" "EARLY_BEFORE_REPLCONF_CAPA_OK no"
        check_file_not_contains "Fake master saw no protocol errors" "$handshake_capture" "ERROR"

        response=$(send_cmd "$handshake_replica_port" PING)
        check_equals "Replica server listens for clients after completing handshake" "$response" "$(printf '+PONG\r')"

        stop_process "$handshake_replica_pid"
    fi
fi

# ---------------------------------------------------------------------------
# 8, 9. Master receives replication handshake
# ---------------------------------------------------------------------------
echo ""
echo "--- Inbound master handshake ---"

inbound_master_port=$(get_free_port)
inbound_log="$TMPDIR_LOCAL/inbound_master.log"
inbound_client_output="$TMPDIR_LOCAL/inbound_client.out"

if start_redis "$inbound_master_port" "$inbound_log" --port "$inbound_master_port"; then
    inbound_master_pid="$LAST_SERVER_PID"

    if run_master_handshake_client "$inbound_master_port" "$inbound_master_port" "$inbound_client_output"; then
        record_pass "Master handles PING, REPLCONF, REPLCONF, PSYNC on one connection"
    else
        record_fail "Master handles PING, REPLCONF, REPLCONF, PSYNC on one connection"
        sed 's/^/    /' "$inbound_client_output" 2>/dev/null || true
    fi

    response=$(send_cmd "$inbound_master_port" REPLCONF)
    check_equals "REPLCONF with no arguments returns +OK" "$response" "$(printf '+OK\r')"

    response=$(send_cmd "$inbound_master_port" REPLCONF listening-port "")
    check_equals "REPLCONF with empty listening-port value returns +OK" "$response" "$(printf '+OK\r')"

    response=$(send_cmd "$inbound_master_port" REPLCONF capa "")
    check_equals "REPLCONF with empty capa value returns +OK" "$response" "$(printf '+OK\r')"

    response=$(send_cmd "$inbound_master_port" PSYNC "?" "-1")
    check_regex "PSYNC ? -1 returns FULLRESYNC with 40-char replid and offset 0" "$response" '^\+FULLRESYNC [[:alnum:]]{40} 0'

    response=$(send_cmd "$inbound_master_port" PSYNC "" "")
    check_regex "PSYNC with empty args still returns a valid FULLRESYNC response" "$response" '^\+FULLRESYNC [[:alnum:]]{40} 0'

    response=$(send_cmd "$inbound_master_port" psync "?" "-1")
    check_regex "PSYNC command is case-insensitive" "$response" '^\+FULLRESYNC [[:alnum:]]{40} 0'

    response=$(send_cmd "$inbound_master_port" PING)
    check_equals "Master remains usable after handshake tests" "$response" "$(printf '+PONG\r')"

    stop_process "$inbound_master_pid"
fi

echo ""
echo "=============================="
echo "Replication test results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi

echo "All replication tests passed!"
