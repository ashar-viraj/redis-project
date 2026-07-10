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

send_psync_and_consume_rdb() {
    local port="$1"
    shift

    python3 - "$port" "$@" <<'PY'
import select
import socket
import sys

port = int(sys.argv[1])
args = sys.argv[2:]

def resp_array(*items):
    out = bytearray()
    out.extend(("*%d\r\n" % len(items)).encode("ascii"))
    for item in items:
        data = str(item).encode("utf-8")
        out.extend(("$%d\r\n" % len(data)).encode("ascii"))
        out.extend(data + b"\r\n")
    return bytes(out)

def read_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)

def read_line(sock):
    data = bytearray()
    while not data.endswith(b"\r\n"):
        chunk = sock.recv(1)
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)

with socket.create_connection(("127.0.0.1", port), timeout=4) as sock:
    sock.settimeout(4)
    sock.sendall(resp_array(*args))
    line = read_line(sock)
    sys.stdout.write(line.decode("utf-8", "replace"))

    readable, _, _ = select.select([sock], [], [], 0.2)
    if readable:
        prefix = read_exact(sock, 1)
        if prefix == b"$":
            length_line = read_line(sock)
            try:
                length = int(length_line[:-2])
            except ValueError:
                length = 0
            if length > 0:
                read_exact(sock, length)
PY
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

wait_for_file_line() {
    local file="$1" line="$2" attempts="${3:-80}" i

    for i in $(seq 1 "$attempts"); do
        if grep -Fxq "$line" "$file" 2>/dev/null; then
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

start_fake_master_for_replica_processing() {
    local port="$1" capture_file="$2"

    python3 - "$port" "$capture_file" <<'PY' &
import select
import socket
import sys
import time

port = int(sys.argv[1])
capture_file = sys.argv[2]
repl_id = "8371b4fb1155b71f4a04d3e1bc3e18c4a990aeeb"
empty_rdb = bytes.fromhex(
    "524544495330303131"
    "fa0972656469732d766572"
    "05372e322e30"
    "fa0a72656469732d62697473"
    "c040"
    "fa056374696d65"
    "c26d08bc65"
    "fa08757365642d6d656d"
    "c2b0c41000"
    "fa08616f662d62617365"
    "c000"
    "fff06e3bfec0ff5aa2"
)

def emit(line):
    with open(capture_file, "a", encoding="utf-8") as f:
        f.write(line + "\n")
        f.flush()

def resp_array(*args):
    out = bytearray()
    out.extend(("*%d\r\n" % len(args)).encode("ascii"))
    for arg in args:
        data = str(arg).encode("utf-8")
        out.extend(("$%d\r\n" % len(data)).encode("ascii"))
        out.extend(data + b"\r\n")
    return bytes(out)

def read_line(conn):
    data = bytearray()
    while not data.endswith(b"\r\n"):
        chunk = conn.recv(1)
        if not chunk:
            raise EOFError("connection closed while reading line")
        data.extend(chunk)
    return bytes(data)

def read_resp_array(conn):
    first = read_line(conn)
    if not first.startswith(b"*"):
        raise ValueError("expected RESP array, got %r" % first)

    count = int(first[1:-2])
    values = []
    for _ in range(count):
        header = read_line(conn)
        if not header.startswith(b"$"):
            raise ValueError("expected bulk string, got %r" % header)

        size = int(header[1:-2])
        payload = bytearray()
        while len(payload) < size + 2:
            chunk = conn.recv(size + 2 - len(payload))
            if not chunk:
                raise EOFError("connection closed while reading bulk string")
            payload.extend(chunk)

        if not payload.endswith(b"\r\n"):
            raise ValueError("bulk string missing CRLF")
        values.append(bytes(payload[:-2]).decode("utf-8", "replace"))

    return values

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

        handshake_responses = [
            b"+PONG\r\n",
            b"+OK\r\n",
            b"+OK\r\n",
        ]

        for index, response in enumerate(handshake_responses, start=1):
            values = read_resp_array(conn)
            emit("CMD %d %s" % (index, " ".join(values)))
            conn.sendall(response)

        values = read_resp_array(conn)
        emit("CMD 4 %s" % " ".join(values))
        conn.sendall(("+FULLRESYNC %s 0\r\n" % repl_id).encode("ascii"))
        conn.sendall(("$%d\r\n" % len(empty_rdb)).encode("ascii"))
        conn.sendall(empty_rdb)
        emit("RDB_SENT %d" % len(empty_rdb))

        time.sleep(0.2)
        conn.sendall(resp_array("SET", "foo", "1"))
        time.sleep(0.1)
        conn.sendall(
            resp_array("SET", "bar", "2") +
            resp_array("SET", "baz", "3") +
            resp_array("SET", "pipe:one", "alpha") +
            resp_array("SET", "pipe:two", "beta")
        )
        emit("PROPAGATION_SENT")

        readable, _, _ = select.select([conn], [], [], 0.8)
        if readable:
            data = conn.recv(1024)
            emit("REPLICA_RESPONSE_AFTER_PROPAGATION %r" % data)
        else:
            emit("NO_RESPONSE_AFTER_PROPAGATION")

        time.sleep(4)
PY
    LAST_FAKE_MASTER_PID=$!
    FAKE_MASTER_PIDS+=("$LAST_FAKE_MASTER_PID")

    for _ in $(seq 1 60); do
        if grep -Fxq "LISTENING $port" "$capture_file" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$LAST_FAKE_MASTER_PID" 2>/dev/null; then
            record_fail "Replica-processing fake master started on port $port"
            sed 's/^/    /' "$capture_file" 2>/dev/null || true
            return 1
        fi
        sleep 0.1
    done

    record_fail "Replica-processing fake master started on port $port"
    fail "  timed out waiting for fake master to listen"
    return 1
}

start_fake_master_for_ack_tests() {
    local port="$1" capture_file="$2" mode="$3"

    python3 - "$port" "$capture_file" "$mode" <<'PY' &
import json
import select
import socket
import sys
import time

port = int(sys.argv[1])
capture_file = sys.argv[2]
mode = sys.argv[3]
repl_id = "8371b4fb1155b71f4a04d3e1bc3e18c4a990aeeb"
empty_rdb = bytes.fromhex(
    "524544495330303131"
    "fa0972656469732d766572"
    "05372e322e30"
    "fa0a72656469732d62697473"
    "c040"
    "fa056374696d65"
    "c26d08bc65"
    "fa08757365642d6d656d"
    "c2b0c41000"
    "fa08616f662d62617365"
    "c000"
    "fff06e3bfec0ff5aa2"
)

def emit(line):
    with open(capture_file, "a", encoding="utf-8") as f:
        f.write(line + "\n")
        f.flush()

def resp_array(*args):
    out = bytearray()
    out.extend(("*%d\r\n" % len(args)).encode("ascii"))
    for arg in args:
        data = str(arg).encode("utf-8")
        out.extend(("$%d\r\n" % len(data)).encode("ascii"))
        out.extend(data + b"\r\n")
    return bytes(out)

def read_line(conn):
    data = bytearray()
    while not data.endswith(b"\r\n"):
        chunk = conn.recv(1)
        if not chunk:
            raise EOFError("connection closed while reading line")
        data.extend(chunk)
    return bytes(data)

def read_resp_array(conn):
    first = read_line(conn)
    if not first.startswith(b"*"):
        raise ValueError("expected RESP array, got %r" % first)

    count = int(first[1:-2])
    values = []
    for _ in range(count):
        header = read_line(conn)
        if not header.startswith(b"$"):
            raise ValueError("expected bulk string, got %r" % header)

        size = int(header[1:-2])
        payload = bytearray()
        while len(payload) < size + 2:
            chunk = conn.recv(size + 2 - len(payload))
            if not chunk:
                raise EOFError("connection closed while reading bulk string")
            payload.extend(chunk)

        if not payload.endswith(b"\r\n"):
            raise ValueError("bulk string missing CRLF")
        values.append(bytes(payload[:-2]).decode("utf-8", "replace"))

    return values

def expect_ack(conn, expected_offset, label):
    values = read_resp_array(conn)
    emit("%s %s" % (label, json.dumps(values)))
    expected = ["REPLCONF", "ACK", str(expected_offset)]
    if values != expected:
        raise AssertionError("%s expected %s, got %s" % (label, expected, values))

def expect_no_response(conn, label):
    readable, _, _ = select.select([conn], [], [], 0.35)
    if readable:
        data = conn.recv(1024)
        emit("%s_UNEXPECTED_RESPONSE %r" % (label, data))
        raise AssertionError("%s unexpectedly received response %r" % (label, data))
    emit("%s_NO_RESPONSE" % label)

def complete_handshake(conn):
    handshake_responses = [
        b"+PONG\r\n",
        b"+OK\r\n",
        b"+OK\r\n",
    ]

    for index, response in enumerate(handshake_responses, start=1):
        values = read_resp_array(conn)
        emit("CMD %d %s" % (index, " ".join(values)))
        conn.sendall(response)

    values = read_resp_array(conn)
    emit("CMD 4 %s" % " ".join(values))
    conn.sendall(("+FULLRESYNC %s 0\r\n" % repl_id).encode("ascii"))
    conn.sendall(("$%d\r\n" % len(empty_rdb)).encode("ascii"))
    conn.sendall(empty_rdb)
    emit("RDB_SENT %d" % len(empty_rdb))

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

    try:
        with conn:
            emit("CONNECTED %s:%d" % addr)
            conn.settimeout(8)
            complete_handshake(conn)
            time.sleep(0.2)

            if mode == "basic":
                conn.sendall(resp_array("REPLCONF", "GETACK", "*"))
                expect_ack(conn, 0, "ACK_NO_COMMANDS")
                emit("ACK_TEST_DONE basic")
            elif mode == "offsets":
                conn.sendall(resp_array("REPLCONF", "GETACK", "*"))
                expect_ack(conn, 0, "ACK_OFFSET_0")

                conn.sendall(resp_array("PING"))
                expect_no_response(conn, "PING")

                conn.sendall(resp_array("REPLCONF", "GETACK", "*"))
                expect_ack(conn, 51, "ACK_OFFSET_51")

                conn.sendall(
                    resp_array("SET", "foo", "1") +
                    resp_array("SET", "bar", "2")
                )
                expect_no_response(conn, "SETS")

                conn.sendall(resp_array("REPLCONF", "GETACK", "*"))
                expect_ack(conn, 146, "ACK_OFFSET_146")
                emit("ACK_TEST_DONE offsets")
            else:
                raise ValueError("unknown ACK test mode %r" % mode)

            time.sleep(1)
    except Exception as exc:
        emit("ERROR %s" % exc)
        raise
PY
    LAST_FAKE_MASTER_PID=$!
    FAKE_MASTER_PIDS+=("$LAST_FAKE_MASTER_PID")

    for _ in $(seq 1 60); do
        if grep -Fxq "LISTENING $port" "$capture_file" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$LAST_FAKE_MASTER_PID" 2>/dev/null; then
            record_fail "ACK fake master started on port $port"
            sed 's/^/    /' "$capture_file" 2>/dev/null || true
            return 1
        fi
        sleep 0.1
    done

    record_fail "ACK fake master started on port $port"
    fail "  timed out waiting for fake master to listen"
    return 1
}

run_master_handshake_client() {
    local port="$1" replica_port="$2" output_file="$3"

    python3 - "$port" "$replica_port" "$output_file" <<'PY'
import re
import select
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

def read_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("connection closed while reading %d bytes" % size)
        data.extend(chunk)
    return bytes(data)

def read_optional_rdb(sock):
    readable, _, _ = select.select([sock], [], [], 0.25)
    if not readable:
        return None

    prefix = read_exact(sock, 1)
    if prefix != b"$":
        raise ValueError("expected RDB bulk prefix '$', got %r" % prefix)

    length_line = read_line(sock)
    try:
        length = int(length_line[:-2])
    except ValueError as exc:
        raise ValueError("invalid RDB length line %r" % length_line) from exc

    if length <= 0:
        raise ValueError("RDB length must be positive, got %d" % length)

    return read_exact(sock, length)

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

        rdb = read_optional_rdb(sock)
        if rdb is None:
            lines.append("RDB after PSYNC => none")
        else:
            lines.append("RDB after PSYNC => %d bytes" % len(rdb))
except Exception as exc:
    lines.append("ERROR %s" % exc)
    raise
finally:
    with open(output_file, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")
PY
}

run_empty_rdb_transfer_client() {
    local port="$1" replica_port="$2" output_file="$3"

    python3 - "$port" "$replica_port" "$output_file" <<'PY'
import re
import select
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

def read_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("connection closed while reading %d bytes" % size)
        data.extend(chunk)
    return bytes(data)

def read_line(sock):
    data = bytearray()
    while not data.endswith(b"\r\n"):
        chunk = sock.recv(1)
        if not chunk:
            raise EOFError("connection closed while reading line")
        data.extend(chunk)
    return bytes(data)

def read_rdb_bulk(sock):
    prefix = read_exact(sock, 1)
    if prefix != b"$":
        raise ValueError("expected RDB bulk prefix '$', got %r" % prefix)

    length_line = read_line(sock)
    try:
        length = int(length_line[:-2])
    except ValueError as exc:
        raise ValueError("invalid RDB length line %r" % length_line) from exc

    if length <= 0:
        raise ValueError("RDB length must be positive, got %d" % length)

    payload = read_exact(sock, length)
    return length, payload

lines = []

try:
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.settimeout(5)

        steps = [
            ("PING", resp_array("PING"), b"+PONG\r\n"),
            (
                "REPLCONF listening-port",
                resp_array("REPLCONF", "listening-port", replica_port),
                b"+OK\r\n",
            ),
            (
                "REPLCONF capa eof capa psync2",
                resp_array("REPLCONF", "capa", "eof", "capa", "psync2"),
                b"+OK\r\n",
            ),
        ]

        for label, request, expected in steps:
            sock.sendall(request)
            response = read_line(sock)
            lines.append("%s => %r" % (label, response))
            if response != expected:
                lines.append("ERROR expected %r" % (expected,))
                raise SystemExit(2)

        sock.sendall(resp_array("PSYNC", "?", "-1"))
        fullresync = read_line(sock)
        lines.append("PSYNC ? -1 => %r" % (fullresync,))
        if not re.fullmatch(rb"\+FULLRESYNC [A-Za-z0-9]{40} 0\r\n", fullresync):
            lines.append("ERROR expected FULLRESYNC with 40-character replid and offset 0")
            raise SystemExit(3)

        length, payload = read_rdb_bulk(sock)
        lines.append("RDB_LENGTH %d" % length)
        lines.append("RDB_MAGIC %r" % payload[:9])
        lines.append("RDB_HEX_PREFIX %s" % payload[:16].hex())
        lines.append("RDB_HEX_SUFFIX %s" % payload[-16:].hex())

        if len(payload) != length:
            lines.append("ERROR RDB payload length mismatch")
            raise SystemExit(4)

        if not re.fullmatch(rb"REDIS[0-9]{4}", payload[:9]):
            lines.append("ERROR RDB payload does not start with REDIS version header")
            raise SystemExit(5)

        lines.append("RDB_MAGIC_OK yes")

        eof_candidates = [
            index for index, byte in enumerate(payload)
            if byte == 0xFF and len(payload) - index >= 9
        ]
        if not eof_candidates:
            lines.append("ERROR RDB payload does not contain EOF marker 0xff followed by an 8-byte checksum")
            raise SystemExit(7)

        eof_index = eof_candidates[0]
        if b"\xfe" in payload[9:eof_index]:
            lines.append("ERROR RDB payload contains a SELECTDB opcode before EOF; expected an empty database snapshot")
            raise SystemExit(8)

        lines.append("RDB_HAS_EOF yes")
        lines.append("RDB_IS_EMPTY yes")

        readable, _, _ = select.select([sock], [], [], 0.2)
        if readable:
            extra = sock.recv(2, socket.MSG_PEEK)
            if extra == b"":
                lines.append("RDB_TRAILING_BYTES none")
            else:
                lines.append("RDB_TRAILING_BYTES %r" % (extra,))
            if extra == b"\r\n":
                lines.append("ERROR RDB bulk payload must not be followed by RESP bulk-string CRLF")
                raise SystemExit(8)
        else:
            lines.append("RDB_TRAILING_BYTES none")
except Exception as exc:
    lines.append("ERROR %s" % exc)
    raise
finally:
    with open(output_file, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")
PY
}

run_single_replica_propagation_client() {
    local port="$1" replica_port="$2" output_file="$3"

    python3 - "$port" "$replica_port" "$output_file" <<'PY'
import json
import re
import select
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

def read_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("connection closed while reading %d bytes" % size)
        data.extend(chunk)
    return bytes(data)

def read_line(sock):
    data = bytearray()
    while not data.endswith(b"\r\n"):
        chunk = sock.recv(1)
        if not chunk:
            raise EOFError("connection closed while reading line")
        data.extend(chunk)
    return bytes(data)

def read_bulk_string(sock):
    header = read_line(sock)
    if not header.startswith(b"$"):
        raise ValueError("expected bulk string, got %r" % header)

    length = int(header[1:-2])
    payload = read_exact(sock, length + 2)
    if not payload.endswith(b"\r\n"):
        raise ValueError("bulk string missing trailing CRLF")
    return payload[:-2].decode("utf-8", "replace")

def read_resp_array(sock):
    first = read_line(sock)
    if not first.startswith(b"*"):
        raise ValueError("expected propagated RESP array, got %r" % first)

    count = int(first[1:-2])
    values = []
    for _ in range(count):
        values.append(read_bulk_string(sock))
    return values

def read_resp_reply(sock):
    first = read_line(sock)
    if first.startswith(b"$"):
        length = int(first[1:-2])
        if length == -1:
            return first
        return first + read_exact(sock, length + 2)
    return first

def read_rdb_bulk(sock):
    prefix = read_exact(sock, 1)
    if prefix != b"$":
        raise ValueError("expected RDB bulk prefix '$', got %r" % prefix)

    length_line = read_line(sock)
    length = int(length_line[:-2])
    if length <= 0:
        raise ValueError("RDB length must be positive, got %d" % length)

    payload = read_exact(sock, length)
    if not re.fullmatch(rb"REDIS[0-9]{4}", payload[:9]):
        raise ValueError("RDB payload does not start with REDIS version header")
    return payload

def send_client_command(*args):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.settimeout(5)
        client.sendall(resp_array(*args))
        return read_resp_reply(client)

def expect_no_propagation(replica, label):
    readable, _, _ = select.select([replica], [], [], 0.35)
    if readable:
        values = read_resp_array(replica)
        raise AssertionError("%s unexpectedly propagated %s" % (label, values))
    lines.append("NO_PROPAGATION %s" % label)

def expect_propagated(replica, expected, index):
    readable, _, _ = select.select([replica], [], [], 3)
    if not readable:
        raise TimeoutError("timed out waiting for propagated command %d: %s" % (index, expected))

    values = read_resp_array(replica)
    lines.append("PROPAGATED %d %s" % (index, json.dumps(values)))
    if values != list(expected):
        raise AssertionError("expected propagated command %s, got %s" % (expected, values))

lines = []

try:
    with socket.create_connection(("127.0.0.1", port), timeout=5) as replica:
        replica.settimeout(5)

        handshake = [
            ("PING", resp_array("PING"), b"+PONG\r\n"),
            (
                "REPLCONF listening-port",
                resp_array("REPLCONF", "listening-port", replica_port),
                b"+OK\r\n",
            ),
            (
                "REPLCONF capa eof capa psync2",
                resp_array("REPLCONF", "capa", "eof", "capa", "psync2"),
                b"+OK\r\n",
            ),
        ]

        for label, request, expected in handshake:
            replica.sendall(request)
            response = read_line(replica)
            lines.append("%s => %r" % (label, response))
            if response != expected:
                raise AssertionError("%s expected %r, got %r" % (label, expected, response))

        replica.sendall(resp_array("PSYNC", "?", "-1"))
        fullresync = read_line(replica)
        lines.append("PSYNC ? -1 => %r" % (fullresync,))
        if not re.fullmatch(rb"\+FULLRESYNC [A-Za-z0-9]{40} 0\r\n", fullresync):
            raise AssertionError("expected FULLRESYNC, got %r" % fullresync)

        rdb = read_rdb_bulk(replica)
        lines.append("RDB_READY %d" % len(rdb))

        response = send_client_command("PING")
        lines.append("CLIENT PING => %r" % response)
        if response != b"+PONG\r\n":
            raise AssertionError("PING client expected +PONG, got %r" % response)
        expect_no_propagation(replica, "PING")

        response = send_client_command("ECHO", "not-a-write")
        lines.append("CLIENT ECHO => %r" % response)
        if response != b"$11\r\nnot-a-write\r\n":
            raise AssertionError("ECHO client got unexpected response %r" % response)
        expect_no_propagation(replica, "ECHO")

        writes = [
            ("SET", "foo", "1"),
            ("SET", "bar", "2"),
            ("SET", "baz", "3"),
            ("SET", "prop:space", "two words"),
            ("SET", "prop:empty", ""),
        ]

        for index, command in enumerate(writes, start=1):
            response = send_client_command(*command)
            lines.append("CLIENT %s => %r" % (" ".join(command), response))
            if response != b"+OK\r\n":
                raise AssertionError("write client expected +OK for %s, got %r" % (command, response))
            expect_propagated(replica, command, index)

        response = send_client_command("GET", "foo")
        lines.append("CLIENT GET foo => %r" % response)
        if response != b"$1\r\n1\r\n":
            raise AssertionError("GET client expected foo=1, got %r" % response)
        expect_no_propagation(replica, "GET")
except Exception as exc:
    lines.append("ERROR %s" % exc)
    raise
finally:
    with open(output_file, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")
PY
}

run_multi_replica_propagation_client() {
    local port="$1" replica_port="$2" output_file="$3"

    python3 - "$port" "$replica_port" "$output_file" <<'PY'
import json
import re
import select
import socket
import sys

port = int(sys.argv[1])
replica_port = sys.argv[2]
output_file = sys.argv[3]
replica_count = 3

def resp_array(*args):
    out = bytearray()
    out.extend(("*%d\r\n" % len(args)).encode("ascii"))
    for arg in args:
        data = str(arg).encode("utf-8")
        out.extend(("$%d\r\n" % len(data)).encode("ascii"))
        out.extend(data + b"\r\n")
    return bytes(out)

def read_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("connection closed while reading %d bytes" % size)
        data.extend(chunk)
    return bytes(data)

def read_line(sock):
    data = bytearray()
    while not data.endswith(b"\r\n"):
        chunk = sock.recv(1)
        if not chunk:
            raise EOFError("connection closed while reading line")
        data.extend(chunk)
    return bytes(data)

def read_bulk_string(sock):
    header = read_line(sock)
    if not header.startswith(b"$"):
        raise ValueError("expected bulk string, got %r" % header)

    length = int(header[1:-2])
    payload = read_exact(sock, length + 2)
    if not payload.endswith(b"\r\n"):
        raise ValueError("bulk string missing trailing CRLF")
    return payload[:-2].decode("utf-8", "replace")

def read_resp_array(sock):
    first = read_line(sock)
    if not first.startswith(b"*"):
        raise ValueError("expected propagated RESP array, got %r" % first)

    count = int(first[1:-2])
    values = []
    for _ in range(count):
        values.append(read_bulk_string(sock))
    return values

def read_resp_reply(sock):
    first = read_line(sock)
    if first.startswith(b"$"):
        length = int(first[1:-2])
        if length == -1:
            return first
        return first + read_exact(sock, length + 2)
    return first

def read_rdb_bulk(sock):
    prefix = read_exact(sock, 1)
    if prefix != b"$":
        raise ValueError("expected RDB bulk prefix '$', got %r" % prefix)

    length_line = read_line(sock)
    length = int(length_line[:-2])
    if length <= 0:
        raise ValueError("RDB length must be positive, got %d" % length)

    payload = read_exact(sock, length)
    if not re.fullmatch(rb"REDIS[0-9]{4}", payload[:9]):
        raise ValueError("RDB payload does not start with REDIS version header")
    return payload

def send_client_command(*args):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.settimeout(5)
        client.sendall(resp_array(*args))
        return read_resp_reply(client)

def connect_replica(replica_index):
    replica = socket.create_connection(("127.0.0.1", port), timeout=5)
    replica.settimeout(5)

    fake_listening_port = str(30000 + replica_index)
    handshake = [
        ("PING", resp_array("PING"), b"+PONG\r\n"),
        (
            "REPLCONF listening-port",
            resp_array("REPLCONF", "listening-port", fake_listening_port),
            b"+OK\r\n",
        ),
        (
            "REPLCONF capa eof capa psync2",
            resp_array("REPLCONF", "capa", "eof", "capa", "psync2"),
            b"+OK\r\n",
        ),
    ]

    for label, request, expected in handshake:
        replica.sendall(request)
        response = read_line(replica)
        lines.append("REPLICA %d %s => %r" % (replica_index, label, response))
        if response != expected:
            raise AssertionError("replica %d %s expected %r, got %r" % (
                replica_index,
                label,
                expected,
                response,
            ))

    replica.sendall(resp_array("PSYNC", "?", "-1"))
    fullresync = read_line(replica)
    lines.append("REPLICA %d PSYNC ? -1 => %r" % (replica_index, fullresync))
    if not re.fullmatch(rb"\+FULLRESYNC [A-Za-z0-9]{40} 0\r\n", fullresync):
        raise AssertionError("replica %d expected FULLRESYNC, got %r" % (replica_index, fullresync))

    rdb = read_rdb_bulk(replica)
    lines.append("REPLICA %d READY" % replica_index)
    lines.append("REPLICA %d READY_BYTES %d" % (replica_index, len(rdb)))
    return replica

def expect_no_propagation_all(replicas, label):
    for replica_index, replica in enumerate(replicas, start=1):
        readable, _, _ = select.select([replica], [], [], 0.35)
        if readable:
            values = read_resp_array(replica)
            raise AssertionError("%s unexpectedly propagated to replica %d: %s" % (
                label,
                replica_index,
                values,
            ))
    lines.append("NO_PROPAGATION_ALL %s" % label)

def expect_propagated_all(replicas, expected, command_index):
    for replica_index, replica in enumerate(replicas, start=1):
        readable, _, _ = select.select([replica], [], [], 3)
        if not readable:
            raise TimeoutError(
                "timed out waiting for command %d on replica %d: %s" %
                (command_index, replica_index, expected)
            )

        values = read_resp_array(replica)
        lines.append("REPLICA %d PROPAGATED %d %s" % (
            replica_index,
            command_index,
            json.dumps(values),
        ))
        if values != list(expected):
            raise AssertionError(
                "replica %d expected propagated command %s, got %s" %
                (replica_index, expected, values)
            )

lines = []
replicas = []

try:
    for replica_index in range(1, replica_count + 1):
        replicas.append(connect_replica(replica_index))

    response = send_client_command("PING")
    lines.append("CLIENT PING => %r" % response)
    if response != b"+PONG\r\n":
        raise AssertionError("PING client expected +PONG, got %r" % response)
    expect_no_propagation_all(replicas, "PING")

    writes = [
        ("SET", "foo", "1"),
        ("SET", "bar", "2"),
        ("SET", "baz", "3"),
        ("SET", "multi:space", "two words"),
    ]

    for command_index, command in enumerate(writes, start=1):
        response = send_client_command(*command)
        lines.append("CLIENT %s => %r" % (" ".join(command), response))
        if response != b"+OK\r\n":
            raise AssertionError("write client expected +OK for %s, got %r" % (command, response))
        expect_propagated_all(replicas, command, command_index)

    response = send_client_command("ECHO", "still-not-a-write")
    lines.append("CLIENT ECHO => %r" % response)
    if response != b"$17\r\nstill-not-a-write\r\n":
        raise AssertionError("ECHO client got unexpected response %r" % response)
    expect_no_propagation_all(replicas, "ECHO")

    lines.append("MULTI_REPLICA_DONE")
except Exception as exc:
    lines.append("ERROR %s" % exc)
    raise
finally:
    for replica in replicas:
        try:
            replica.close()
        except Exception:
            pass

    with open(output_file, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")
PY
}

run_wait_with_multiple_commands_client() {
    local port="$1" output_file="$2" scenario="$3"

    python3 - "$port" "$output_file" "$scenario" <<'PY'
import json
import re
import select
import socket
import sys
import time

port = int(sys.argv[1])
output_file = sys.argv[2]
scenario = sys.argv[3]

def resp_array(*args):
    out = bytearray()
    out.extend(("*%d\r\n" % len(args)).encode("ascii"))
    for arg in args:
        data = str(arg).encode("utf-8")
        out.extend(("$%d\r\n" % len(data)).encode("ascii"))
        out.extend(data + b"\r\n")
    return bytes(out)

def read_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("connection closed while reading %d bytes" % size)
        data.extend(chunk)
    return bytes(data)

def read_line(sock):
    data = bytearray()
    while not data.endswith(b"\r\n"):
        chunk = sock.recv(1)
        if not chunk:
            raise EOFError("connection closed while reading line")
        data.extend(chunk)
    return bytes(data)

def read_bulk_string_with_raw(sock):
    raw = bytearray()
    header = read_line(sock)
    raw.extend(header)
    if not header.startswith(b"$"):
        raise ValueError("expected bulk string, got %r" % header)

    length = int(header[1:-2])
    payload = read_exact(sock, length + 2)
    raw.extend(payload)
    if not payload.endswith(b"\r\n"):
        raise ValueError("bulk string missing trailing CRLF")
    return payload[:-2].decode("utf-8", "replace"), bytes(raw)

def read_resp_array_with_raw(sock):
    raw = bytearray()
    first = read_line(sock)
    raw.extend(first)
    if not first.startswith(b"*"):
        raise ValueError("expected RESP array, got %r" % first)

    count = int(first[1:-2])
    values = []
    for _ in range(count):
        value, part = read_bulk_string_with_raw(sock)
        values.append(value)
        raw.extend(part)
    return values, bytes(raw)

def read_resp_reply(sock):
    first = read_line(sock)
    if first.startswith(b"$"):
        length = int(first[1:-2])
        if length == -1:
            return first
        return first + read_exact(sock, length + 2)
    return first

def read_resp_integer(sock):
    line = read_line(sock)
    if not line.startswith(b":"):
        raise ValueError("expected RESP integer, got %r" % line)
    return int(line[1:-2])

def read_rdb_bulk(sock):
    prefix = read_exact(sock, 1)
    if prefix != b"$":
        raise ValueError("expected RDB bulk prefix '$', got %r" % prefix)

    length = int(read_line(sock)[:-2])
    payload = read_exact(sock, length)
    if not re.fullmatch(rb"REDIS[0-9]{4}", payload[:9]):
        raise ValueError("RDB payload does not start with REDIS version header")
    return payload

def send_client_command(*args):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.settimeout(5)
        client.sendall(resp_array(*args))
        return read_resp_reply(client)

def connect_replica(replica_index, behavior):
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    sock.settimeout(5)

    handshake = [
        (resp_array("PING"), b"+PONG\r\n"),
        (resp_array("REPLCONF", "listening-port", str(31000 + replica_index)), b"+OK\r\n"),
        (resp_array("REPLCONF", "capa", "eof", "capa", "psync2"), b"+OK\r\n"),
    ]

    for request, expected in handshake:
        sock.sendall(request)
        response = read_line(sock)
        if response != expected:
            raise AssertionError("replica %d handshake expected %r, got %r" % (
                replica_index,
                expected,
                response,
            ))

    sock.sendall(resp_array("PSYNC", "?", "-1"))
    fullresync = read_line(sock)
    if not re.fullmatch(rb"\+FULLRESYNC [A-Za-z0-9]{40} 0\r\n", fullresync):
        raise AssertionError("replica %d expected FULLRESYNC, got %r" % (replica_index, fullresync))

    rdb = read_rdb_bulk(sock)
    lines.append("WAIT_REPLICA %d READY %s" % (replica_index, behavior))
    lines.append("WAIT_REPLICA %d READY_BYTES %d" % (replica_index, len(rdb)))
    return {
        "index": replica_index,
        "behavior": behavior,
        "sock": sock,
        "offset": 0,
        "acks": 0,
    }

def is_getack(values):
    return (
        len(values) == 3 and
        values[0].upper() == "REPLCONF" and
        values[1].upper() == "GETACK" and
        values[2] == "*"
    )

def process_replica_command(replica):
    values, raw = read_resp_array_with_raw(replica["sock"])
    lines.append("WAIT_REPLICA %d RECEIVED %s" % (
        replica["index"],
        json.dumps(values),
    ))

    if is_getack(values):
        behavior = replica["behavior"]
        if behavior == "good":
            ack_offset = replica["offset"]
            replica["sock"].sendall(resp_array("REPLCONF", "ACK", str(ack_offset)))
            lines.append("WAIT_REPLICA %d ACK %d" % (replica["index"], ack_offset))
        elif behavior == "stale":
            replica["sock"].sendall(resp_array("REPLCONF", "ACK", "0"))
            lines.append("WAIT_REPLICA %d ACK_STALE 0" % replica["index"])
        elif behavior == "invalid":
            replica["sock"].sendall(resp_array("REPLCONF", "NOPE", "0"))
            lines.append("WAIT_REPLICA %d ACK_INVALID" % replica["index"])
        elif behavior == "silent":
            lines.append("WAIT_REPLICA %d ACK_SILENT" % replica["index"])
        else:
            raise ValueError("unknown replica behavior %r" % behavior)
        replica["offset"] += len(raw)
        replica["acks"] += 1
        return "getack"

    replica["offset"] += len(raw)
    return "command"

def drain_expected_propagation(replicas, expected_commands):
    for expected in expected_commands:
        for replica in replicas:
            readable, _, _ = select.select([replica["sock"]], [], [], 3)
            if not readable:
                raise TimeoutError("replica %d did not receive propagated %s" % (
                    replica["index"],
                    expected,
                ))
            before = replica["offset"]
            kind = process_replica_command(replica)
            if kind != "command":
                raise AssertionError("expected propagated command, got GETACK")
            lines.append("WAIT_REPLICA %d OFFSET %d->%d" % (
                replica["index"],
                before,
                replica["offset"],
            ))

def wait_command(num_replicas, timeout_ms, expected_count, label, replicas):
    client = socket.create_connection(("127.0.0.1", port), timeout=5)
    client.settimeout(5)
    client.sendall(resp_array("WAIT", str(num_replicas), str(timeout_ms)))

    deadline = time.time() + (timeout_ms / 1000.0) + 1.5
    result = None
    while time.time() < deadline:
        sockets = [client] + [replica["sock"] for replica in replicas]
        readable, _, _ = select.select(sockets, [], [], 0.05)
        for sock in readable:
            if sock is client:
                result = read_resp_integer(client)
                break

            for replica in replicas:
                if sock is replica["sock"]:
                    process_replica_command(replica)
                    break
        if result is not None:
            break

    client.close()
    if result is None:
        raise TimeoutError("%s did not return a WAIT response" % label)

    lines.append("%s WAIT_RESULT %d" % (label, result))
    if result != expected_count:
        raise AssertionError("%s expected WAIT result %d, got %d" % (label, expected_count, result))

def run_scenario():
    if scenario == "all_ack":
        behaviors = ["good", "good", "good"]
        writes = [("SET", "foo", "123"), ("SET", "bar", "456")]
        wait_args = (3, 700, 3, "WAIT_ALL_ACK")
    elif scenario == "partial_timeout":
        behaviors = ["good", "good", "silent"]
        writes = [("SET", "foo", "123"), ("SET", "bar", "456")]
        wait_args = (3, 250, 2, "WAIT_PARTIAL_TIMEOUT")
    elif scenario == "stale_invalid":
        behaviors = ["good", "good", "stale", "invalid"]
        writes = [("SET", "foo", "123"), ("SET", "bar", "456"), ("SET", "baz", "789")]
        wait_args = (3, 300, 2, "WAIT_STALE_INVALID")
    else:
        raise ValueError("unknown WAIT scenario %r" % scenario)

    replicas = [
        connect_replica(index, behavior)
        for index, behavior in enumerate(behaviors, start=1)
    ]

    try:
        for command in writes:
            response = send_client_command(*command)
            lines.append("%s CLIENT %s => %r" % (scenario, " ".join(command), response))
            if response != b"+OK\r\n":
                raise AssertionError("SET expected +OK, got %r" % response)

        drain_expected_propagation(replicas, writes)
        wait_command(*wait_args, replicas=replicas)
        lines.append("%s DONE" % scenario)
    finally:
        for replica in replicas:
            try:
                replica["sock"].close()
            except Exception:
                pass

lines = []

try:
    run_scenario()
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
    if [ -n "$response" ]; then
        check_resp_reply "REPLCONF with empty listening-port value returns a RESP reply" "$response"
    else
        record_skip "REPLCONF with empty listening-port value produced no response; this is outside the stage requirement"
    fi

    response=$(send_cmd "$inbound_master_port" REPLCONF capa "")
    check_equals "REPLCONF with empty capa value returns +OK" "$response" "$(printf '+OK\r')"

    response=$(send_cmd "$inbound_master_port" PING)
    check_equals "Master remains usable after REPLCONF edge cases" "$response" "$(printf '+PONG\r')"

    response=$(send_psync_and_consume_rdb "$inbound_master_port" PSYNC "?" "-1")
    check_regex "PSYNC ? -1 returns FULLRESYNC with 40-char replid and offset 0" "$response" '^\+FULLRESYNC [[:alnum:]]{40} 0'

    response=$(send_psync_and_consume_rdb "$inbound_master_port" PSYNC "" "")
    check_regex "PSYNC with empty args still returns a valid FULLRESYNC response" "$response" '^\+FULLRESYNC [[:alnum:]]{40} 0'

    response=$(send_psync_and_consume_rdb "$inbound_master_port" psync "?" "-1")
    check_regex "PSYNC command is case-insensitive" "$response" '^\+FULLRESYNC [[:alnum:]]{40} 0'

    stop_process "$inbound_master_pid"
fi

# ---------------------------------------------------------------------------
# 10. Empty RDB transfer after FULLRESYNC
# ---------------------------------------------------------------------------
echo ""
echo "--- Empty RDB transfer ---"

rdb_master_port=$(get_free_port)
rdb_log="$TMPDIR_LOCAL/rdb_master.log"
rdb_client_output="$TMPDIR_LOCAL/rdb_client.out"

if start_redis "$rdb_master_port" "$rdb_log" --port "$rdb_master_port"; then
    rdb_master_pid="$LAST_SERVER_PID"

    if run_empty_rdb_transfer_client "$rdb_master_port" "$rdb_master_port" "$rdb_client_output"; then
        record_pass "Master sends an empty RDB bulk payload after FULLRESYNC"
        check_file_contains_line "RDB transfer used REPLCONF capa eof capa psync2" "$rdb_client_output" "REPLCONF capa eof capa psync2 => b'+OK\\r\\n'"
        check_file_contains_line "RDB payload has a Redis RDB header" "$rdb_client_output" "RDB_MAGIC_OK yes"
        check_file_contains_line "RDB payload contains EOF marker and checksum area" "$rdb_client_output" "RDB_HAS_EOF yes"
        check_file_contains_line "RDB payload represents an empty database snapshot" "$rdb_client_output" "RDB_IS_EMPTY yes"
        check_file_contains_line "RDB payload is not followed by bulk-string CRLF" "$rdb_client_output" "RDB_TRAILING_BYTES none"
    else
        record_fail "Master sends an empty RDB bulk payload after FULLRESYNC"
        sed 's/^/    /' "$rdb_client_output" 2>/dev/null || true
    fi

    stop_process "$rdb_master_pid"
fi

# ---------------------------------------------------------------------------
# 11. Single-replica propagation
# ---------------------------------------------------------------------------
echo ""
echo "--- Single-replica propagation ---"

prop_master_port=$(get_free_port)
prop_log="$TMPDIR_LOCAL/prop_master.log"
prop_client_output="$TMPDIR_LOCAL/prop_client.out"

if start_redis "$prop_master_port" "$prop_log" --port "$prop_master_port"; then
    prop_master_pid="$LAST_SERVER_PID"

    if run_single_replica_propagation_client "$prop_master_port" "$prop_master_port" "$prop_client_output"; then
        record_pass "Master propagates write commands to one replica over the handshake connection"
        check_file_not_contains "Propagation helper saw no errors" "$prop_client_output" "ERROR"
        check_file_contains_line "PING is not propagated to replica" "$prop_client_output" "NO_PROPAGATION PING"
        check_file_contains_line "ECHO is not propagated to replica" "$prop_client_output" "NO_PROPAGATION ECHO"
        check_file_contains_line "GET is not propagated to replica" "$prop_client_output" "NO_PROPAGATION GET"
        check_file_contains_line "First SET propagated in order" "$prop_client_output" 'PROPAGATED 1 ["SET", "foo", "1"]'
        check_file_contains_line "Second SET propagated in order" "$prop_client_output" 'PROPAGATED 2 ["SET", "bar", "2"]'
        check_file_contains_line "Third SET propagated in order" "$prop_client_output" 'PROPAGATED 3 ["SET", "baz", "3"]'
        check_file_contains_line "SET with spaces in value is propagated" "$prop_client_output" 'PROPAGATED 4 ["SET", "prop:space", "two words"]'
        check_file_contains_line "SET with empty value is propagated" "$prop_client_output" 'PROPAGATED 5 ["SET", "prop:empty", ""]'
    else
        record_fail "Master propagates write commands to one replica over the handshake connection"
        sed 's/^/    /' "$prop_client_output" 2>/dev/null || true
    fi

    stop_process "$prop_master_pid"
fi

# ---------------------------------------------------------------------------
# 12. Multi-replica propagation
# ---------------------------------------------------------------------------
echo ""
echo "--- Multi-replica propagation ---"

multi_prop_master_port=$(get_free_port)
multi_prop_log="$TMPDIR_LOCAL/multi_prop_master.log"
multi_prop_client_output="$TMPDIR_LOCAL/multi_prop_client.out"

if start_redis "$multi_prop_master_port" "$multi_prop_log" --port "$multi_prop_master_port"; then
    multi_prop_master_pid="$LAST_SERVER_PID"

    if run_multi_replica_propagation_client "$multi_prop_master_port" "$multi_prop_master_port" "$multi_prop_client_output"; then
        record_pass "Master propagates write commands to all connected replicas"
        check_file_not_contains "Multi-replica helper saw no errors" "$multi_prop_client_output" "ERROR"
        check_file_contains_line "Replica 1 completed full sync" "$multi_prop_client_output" "REPLICA 1 READY"
        check_file_contains_line "Replica 2 completed full sync" "$multi_prop_client_output" "REPLICA 2 READY"
        check_file_contains_line "Replica 3 completed full sync" "$multi_prop_client_output" "REPLICA 3 READY"
        check_file_contains_line "PING is not propagated to any replica" "$multi_prop_client_output" "NO_PROPAGATION_ALL PING"
        check_file_contains_line "ECHO is not propagated to any replica" "$multi_prop_client_output" "NO_PROPAGATION_ALL ECHO"
        check_file_contains_line "Replica 1 receives SET foo first" "$multi_prop_client_output" 'REPLICA 1 PROPAGATED 1 ["SET", "foo", "1"]'
        check_file_contains_line "Replica 2 receives SET foo first" "$multi_prop_client_output" 'REPLICA 2 PROPAGATED 1 ["SET", "foo", "1"]'
        check_file_contains_line "Replica 3 receives SET foo first" "$multi_prop_client_output" 'REPLICA 3 PROPAGATED 1 ["SET", "foo", "1"]'
        check_file_contains_line "Replica 1 receives SET bar second" "$multi_prop_client_output" 'REPLICA 1 PROPAGATED 2 ["SET", "bar", "2"]'
        check_file_contains_line "Replica 2 receives SET bar second" "$multi_prop_client_output" 'REPLICA 2 PROPAGATED 2 ["SET", "bar", "2"]'
        check_file_contains_line "Replica 3 receives SET bar second" "$multi_prop_client_output" 'REPLICA 3 PROPAGATED 2 ["SET", "bar", "2"]'
        check_file_contains_line "Replica 1 receives SET baz third" "$multi_prop_client_output" 'REPLICA 1 PROPAGATED 3 ["SET", "baz", "3"]'
        check_file_contains_line "Replica 2 receives SET baz third" "$multi_prop_client_output" 'REPLICA 2 PROPAGATED 3 ["SET", "baz", "3"]'
        check_file_contains_line "Replica 3 receives SET baz third" "$multi_prop_client_output" 'REPLICA 3 PROPAGATED 3 ["SET", "baz", "3"]'
        check_file_contains_line "All multi-replica propagation checks completed" "$multi_prop_client_output" "MULTI_REPLICA_DONE"
    else
        record_fail "Master propagates write commands to all connected replicas"
        sed 's/^/    /' "$multi_prop_client_output" 2>/dev/null || true
    fi

    stop_process "$multi_prop_master_pid"
fi

# ---------------------------------------------------------------------------
# 13. Replica processes propagated commands
# ---------------------------------------------------------------------------
echo ""
echo "--- Replica command processing ---"

replica_processing_master_port=$(get_free_port)
replica_processing_port=$(get_free_port)
replica_processing_capture="$TMPDIR_LOCAL/replica_processing_master.capture"
replica_processing_log="$TMPDIR_LOCAL/replica_processing_replica.log"

if start_fake_master_for_replica_processing "$replica_processing_master_port" "$replica_processing_capture"; then
    if start_redis "$replica_processing_port" "$replica_processing_log" \
        --port "$replica_processing_port" \
        --replicaof "127.0.0.1 $replica_processing_master_port"; then
        replica_processing_pid="$LAST_SERVER_PID"

        if wait_for_file_line "$replica_processing_capture" "PROPAGATION_SENT"; then
            check_file_contains_line "Replica connected to fake master" "$replica_processing_capture" "CMD 1 PING"
            check_file_contains_line "Replica requested full sync" "$replica_processing_capture" "CMD 4 PSYNC ? -1"
            check_file_contains_line "Fake master sent an empty RDB" "$replica_processing_capture" "RDB_SENT 88"

            response=$(send_cmd "$replica_processing_port" GET foo)
            check_equals "Replica applied propagated SET foo 1" "$response" "$(printf '$1\r\n1\r')"

            response=$(send_cmd "$replica_processing_port" GET bar)
            check_equals "Replica applied propagated SET bar 2" "$response" "$(printf '$1\r\n2\r')"

            response=$(send_cmd "$replica_processing_port" GET baz)
            check_equals "Replica applied propagated SET baz 3" "$response" "$(printf '$1\r\n3\r')"

            response=$(send_cmd "$replica_processing_port" GET pipe:one)
            check_equals "Replica processed first command from pipelined propagation batch" "$response" "$(printf '$5\r\nalpha\r')"

            response=$(send_cmd "$replica_processing_port" GET pipe:two)
            check_equals "Replica processed second command from pipelined propagation batch" "$response" "$(printf '$4\r\nbeta\r')"

            if wait_for_file_line "$replica_processing_capture" "NO_RESPONSE_AFTER_PROPAGATION" 15; then
                record_pass "Replica does not reply to propagated commands from master"
            else
                record_fail "Replica does not reply to propagated commands from master"
                sed 's/^/    /' "$replica_processing_capture" 2>/dev/null || true
            fi
            check_file_not_contains "Fake master saw no propagated-command replies" "$replica_processing_capture" "REPLICA_RESPONSE_AFTER_PROPAGATION"
        else
            record_fail "Fake master sent propagated commands to replica"
            sed 's/^/    /' "$replica_processing_capture" 2>/dev/null || true
            fail "  replica log:"
            sed 's/^/    /' "$replica_processing_log" 2>/dev/null || true
        fi

        stop_process "$replica_processing_pid"
    fi
fi

# ---------------------------------------------------------------------------
# 14. ACKs with no commands
# ---------------------------------------------------------------------------
echo ""
echo "--- ACKs with no commands ---"

ack_basic_master_port=$(get_free_port)
ack_basic_replica_port=$(get_free_port)
ack_basic_capture="$TMPDIR_LOCAL/ack_basic_master.capture"
ack_basic_log="$TMPDIR_LOCAL/ack_basic_replica.log"

if start_fake_master_for_ack_tests "$ack_basic_master_port" "$ack_basic_capture" basic; then
    if start_redis "$ack_basic_replica_port" "$ack_basic_log" \
        --port "$ack_basic_replica_port" \
        --replicaof "127.0.0.1 $ack_basic_master_port"; then
        ack_basic_pid="$LAST_SERVER_PID"

        if wait_for_file_line "$ack_basic_capture" "ACK_TEST_DONE basic"; then
            check_file_not_contains "ACK/no-command fake master saw no errors" "$ack_basic_capture" "ERROR"
            check_file_contains_line "Replica completed handshake before ACK request" "$ack_basic_capture" "CMD 4 PSYNC ? -1"
            check_file_contains_line "Replica ACKs zero when no propagated commands were processed" "$ack_basic_capture" 'ACK_NO_COMMANDS ["REPLCONF", "ACK", "0"]'
        else
            record_fail "Replica responds to REPLCONF GETACK * with ACK 0"
            sed 's/^/    /' "$ack_basic_capture" 2>/dev/null || true
            fail "  replica log:"
            sed 's/^/    /' "$ack_basic_log" 2>/dev/null || true
        fi

        stop_process "$ack_basic_pid"
    fi
fi

# ---------------------------------------------------------------------------
# 15. ACKs with commands
# ---------------------------------------------------------------------------
echo ""
echo "--- ACKs with commands ---"

ack_offsets_master_port=$(get_free_port)
ack_offsets_replica_port=$(get_free_port)
ack_offsets_capture="$TMPDIR_LOCAL/ack_offsets_master.capture"
ack_offsets_log="$TMPDIR_LOCAL/ack_offsets_replica.log"

if start_fake_master_for_ack_tests "$ack_offsets_master_port" "$ack_offsets_capture" offsets; then
    if start_redis "$ack_offsets_replica_port" "$ack_offsets_log" \
        --port "$ack_offsets_replica_port" \
        --replicaof "127.0.0.1 $ack_offsets_master_port"; then
        ack_offsets_pid="$LAST_SERVER_PID"

        if wait_for_file_line "$ack_offsets_capture" "ACK_TEST_DONE offsets"; then
            check_file_not_contains "ACK/offset fake master saw no errors" "$ack_offsets_capture" "ERROR"
            check_file_contains_line "Initial GETACK returns ACK 0" "$ack_offsets_capture" 'ACK_OFFSET_0 ["REPLCONF", "ACK", "0"]'
            check_file_contains_line "Replica does not respond to propagated PING" "$ack_offsets_capture" "PING_NO_RESPONSE"
            check_file_contains_line "GETACK after PING returns ACK 51" "$ack_offsets_capture" 'ACK_OFFSET_51 ["REPLCONF", "ACK", "51"]'
            check_file_contains_line "Replica does not respond to propagated SET commands" "$ack_offsets_capture" "SETS_NO_RESPONSE"
            check_file_contains_line "GETACK after two SETs returns ACK 146" "$ack_offsets_capture" 'ACK_OFFSET_146 ["REPLCONF", "ACK", "146"]'
        else
            record_fail "Replica tracks processed-byte offsets for REPLCONF ACK"
            sed 's/^/    /' "$ack_offsets_capture" 2>/dev/null || true
            fail "  replica log:"
            sed 's/^/    /' "$ack_offsets_log" 2>/dev/null || true
        fi

        stop_process "$ack_offsets_pid"
    fi
fi

# ---------------------------------------------------------------------------
# 16. WAIT with multiple propagated commands
# ---------------------------------------------------------------------------
echo ""
echo "--- WAIT with multiple commands ---"

run_wait_scenario_case() {
    local scenario="$1" title="$2" expected_line="$3"
    local wait_port wait_log wait_output wait_pid

    wait_port=$(get_free_port)
    wait_log="$TMPDIR_LOCAL/wait_${scenario}.log"
    wait_output="$TMPDIR_LOCAL/wait_${scenario}.out"

    if start_redis "$wait_port" "$wait_log" --port "$wait_port"; then
        wait_pid="$LAST_SERVER_PID"

        if run_wait_with_multiple_commands_client "$wait_port" "$wait_output" "$scenario"; then
            record_pass "$title"
            check_file_not_contains "$title: helper saw no errors" "$wait_output" "ERROR"
            check_file_contains_line "$title: expected WAIT result" "$wait_output" "$expected_line"
            check_file_contains_line "$title: scenario completed" "$wait_output" "$scenario DONE"

            case "$scenario" in
                all_ack)
                    check_file_contains_line "$title: all replicas became ready" "$wait_output" "WAIT_REPLICA 3 READY good"
                    check_file_contains_line "$title: third replica ACKed latest write offset" "$wait_output" "WAIT_REPLICA 3 ACK 62"
                    ;;
                partial_timeout)
                    check_file_contains_line "$title: silent replica did not ACK" "$wait_output" "WAIT_REPLICA 3 ACK_SILENT"
                    check_file_contains_line "$title: two good replicas ACKed latest write offset" "$wait_output" "WAIT_REPLICA 2 ACK 62"
                    ;;
                stale_invalid)
                    check_file_contains_line "$title: stale ACK was produced" "$wait_output" "WAIT_REPLICA 3 ACK_STALE 0"
                    check_file_contains_line "$title: invalid ACK was produced" "$wait_output" "WAIT_REPLICA 4 ACK_INVALID"
                    ;;
            esac
        else
            record_fail "$title"
            sed 's/^/    /' "$wait_output" 2>/dev/null || true
            fail "  master log:"
            sed 's/^/    /' "$wait_log" 2>/dev/null || true
        fi

        stop_process "$wait_pid"
    fi
}

run_wait_scenario_case \
    all_ack \
    "WAIT returns all replicas after multiple writes when every replica ACKs" \
    "WAIT_ALL_ACK WAIT_RESULT 3"

run_wait_scenario_case \
    partial_timeout \
    "WAIT returns only ACKed replicas when one replica times out" \
    "WAIT_PARTIAL_TIMEOUT WAIT_RESULT 2"

run_wait_scenario_case \
    stale_invalid \
    "WAIT ignores stale and invalid ACK responses" \
    "WAIT_STALE_INVALID WAIT_RESULT 2"

echo ""
echo "=============================="
echo "Replication test results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi

echo "All replication tests passed!"
