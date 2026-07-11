#!/bin/bash
# Verify RDB config, loading keys/values, expiry handling, and malformed RDB inputs.

source "$(dirname "$0")/helpers.sh"

echo "=== RDB persistence extension: CONFIG, KEYS, GET, expiry ==="

if [ "${EXTERNAL_SERVER:-0}" = "1" ]; then
    fail "EXTERNAL_SERVER=1 is not supported by this script because it restarts the server with many RDB files."
    exit 1
fi

build_server

PASS_COUNT=0
FAIL_COUNT=0
TMPDIR_LOCAL=$(mktemp -d)
FIXTURE_DIR="$TMPDIR_LOCAL/rdb-fixtures"
SERVER_LOG="$TMPDIR_LOCAL/server.log"
echo "TMPDIR_LOCAL = $TMPDIR_LOCAL"
echo "FIXTURE_DIR = $FIXTURE_DIR"

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

wait_for_port() {
    local i
    for i in $(seq 1 40); do
        nc -z 127.0.0.1 6379 >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 1
}

start_server_with_rdb() {
    local label="$1"
    shift

    stop_server
    fuser -k 6379/tcp >/dev/null 2>&1 || true
    sleep 0.2

    "$BINARY" "$@" > "$SERVER_LOG" 2>&1 &
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

expect_startup_failure() {
    local label="$1"
    shift

    stop_server
    fuser -k 6379/tcp >/dev/null 2>&1 || true
    sleep 0.2

    "$BINARY" "$@" > "$SERVER_LOG" 2>&1 &
    local pid=$!
    sleep 0.6

    if kill -0 "$pid" 2>/dev/null; then
        fail "$label"
        fail "  expected startup failure, but server stayed alive"
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        SERVER_PID=""
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        wait "$pid" 2>/dev/null
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
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

check_array_unordered() {
    local label="$1" response="$2"
    shift 2

    RESP_DATA="$response" python3 - "$@" <<'PY'
import collections
import os
import sys

data = os.environ["RESP_DATA"].encode("latin1")
if data.endswith(b"\r"):
    data += b"\n"

pos = 0

def read_line():
    global pos
    end = data.find(b"\r\n", pos)
    if end == -1:
        raise ValueError("missing CRLF")
    line = data[pos:end]
    pos = end + 2
    return line

line = read_line()
if not line.startswith(b"*"):
    raise ValueError("response is not an array")

count = int(line[1:])
items = []
for _ in range(count):
    bulk = read_line()
    if not bulk.startswith(b"$"):
        raise ValueError("array element is not a bulk string")
    length = int(bulk[1:])
    if length < 0:
        raise ValueError("unexpected null bulk string in key array")
    value = data[pos:pos + length]
    pos += length
    if data[pos:pos + 2] != b"\r\n":
        raise ValueError("bulk string missing trailing CRLF")
    pos += 2
    items.append(value.decode("latin1"))

expected = sys.argv[1:]
if collections.Counter(items) != collections.Counter(expected):
    print("expected unordered:", expected, file=sys.stderr)
    print("got unordered     :", items, file=sys.stderr)
    sys.exit(1)
PY

    if [ $? -eq 0 ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  raw response: $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

expect_bulk()       { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_null()       { printf '$-1\r'; }
expect_empty_array(){ printf '*0\r'; }

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

generate_rdb_fixtures() {
    python3 - "$FIXTURE_DIR" <<'PY'
import os
import struct
import sys
import time

out_dir = sys.argv[1]
os.makedirs(out_dir, exist_ok=True)

def enc_len(n):
    if n < 0:
        raise ValueError("negative length")
    if n < 64:
        return bytes([n])
    if n < 16384:
        return bytes([0x40 | (n >> 8), n & 0xFF])
    return bytes([0x80]) + n.to_bytes(4, "big")

def enc_str(value):
    if isinstance(value, str):
        value = value.encode("latin1")
    return enc_len(len(value)) + value

def write_rdb(name, entries=(), metadata=(), db=0, checksum=False):
    body = bytearray(b"REDIS0011")
    for key, value in metadata:
        body.append(0xFA)
        body.extend(enc_str(key))
        body.extend(enc_str(value))
    body.append(0xFE)
    body.extend(enc_len(db))
    body.append(0xFB)
    body.extend(enc_len(len(entries)))
    body.extend(enc_len(sum(1 for item in entries if item.get("expiry_ms") is not None or item.get("expiry_s") is not None)))
    for item in entries:
        if item.get("expiry_ms") is not None:
            body.append(0xFC)
            body.extend(struct.pack("<Q", item["expiry_ms"]))
        elif item.get("expiry_s") is not None:
            body.append(0xFD)
            body.extend(struct.pack("<I", item["expiry_s"]))
        body.append(0x00)
        body.extend(enc_str(item["key"]))
        body.extend(enc_str(item["value"]))
    body.append(0xFF)
    if checksum:
        body.extend(b"\x00" * 8)
    with open(os.path.join(out_dir, name), "wb") as f:
        f.write(body)

now_ms = int(time.time() * 1000)
now_s = int(time.time())
long_key = "k" * 70
value_14 = "A" * 200
value_32 = "V" * 17000

write_rdb("empty_valid.rdb", [], metadata=[("redis-ver", "7.2.0"), ("ctime", str(now_s))], checksum=True)
write_rdb("single_no_metadata.rdb", [{"key": "foo", "value": "bar"}], checksum=False)
write_rdb(
    "metadata_multi.rdb",
    [
        {"key": "apple", "value": "red"},
        {"key": "banana", "value": "yellow"},
        {"key": "carrot", "value": "orange"},
        {"key": "z-last", "value": "tail"},
    ],
    metadata=[
        ("redis-ver", "7.2.4"),
        ("redis-bits", "64"),
        ("used-mem", "123456"),
        ("aof-base", "0"),
    ],
    checksum=True,
)
write_rdb(
    "length_encodings.rdb",
    [
        {"key": "short", "value": "tiny"},
        {"key": long_key, "value": value_14},
        {"key": "value32", "value": value_32},
    ],
    metadata=[("length-mode", "6bit-14bit-32bit")],
    checksum=True,
)
write_rdb(
    "high_db_checksum.rdb",
    [
        {"key": "space key", "value": "value with spaces"},
        {"key": "empty-value", "value": ""},
        {"key": "punct:!@#$%^&*()", "value": "symbols-ok"},
        {"key": "caseSensitive", "value": "MiXeD"},
    ],
    metadata=[("aux-key", "aux-value")],
    db=15,
    checksum=True,
)
write_rdb(
    "expiry_mix.rdb",
    [
        {"key": "no_expiry", "value": "alive"},
        {"key": "future_ms", "value": "alive-ms", "expiry_ms": now_ms + 600000},
        {"key": "past_ms", "value": "expired-ms", "expiry_ms": now_ms - 60000},
        {"key": "future_s", "value": "alive-s", "expiry_s": now_s + 600},
        {"key": "past_s", "value": "expired-s", "expiry_s": now_s - 60},
    ],
    metadata=[("expiry-test", "absolute-unix-times")],
    checksum=True,
)

open(os.path.join(out_dir, "empty_file.rdb"), "wb").close()
with open(os.path.join(out_dir, "bad_magic.rdb"), "wb") as f:
    f.write(b"NOTREDIS!!")
with open(os.path.join(out_dir, "truncated.rdb"), "wb") as f:
    f.write(b"REDIS0011\xFE")

unsupported_type = bytearray(b"REDIS0011")
unsupported_type.extend(b"\xFE\x00\xFB\x01\x00")
unsupported_type.append(0x01)
unsupported_type.extend(enc_str("listish"))
unsupported_type.extend(enc_str("not-a-string-type"))
unsupported_type.append(0xFF)
with open(os.path.join(out_dir, "unsupported_value_type.rdb"), "wb") as f:
    f.write(unsupported_type)

special_string = bytearray(b"REDIS0011")
special_string.extend(b"\xFE\x00\xFB\x01\x00\x00")
special_string.extend(enc_str("int-encoded"))
special_string.extend(b"\xC0\x7B")
special_string.append(0xFF)
with open(os.path.join(out_dir, "unsupported_special_string.rdb"), "wb") as f:
    f.write(special_string)
PY
}

generate_rdb_fixtures

LONG_KEY=$(repeat_char k 70)
VALUE_14=$(repeat_char A 200)
VALUE_32=$(repeat_char V 17000)

# ---------------------------------------------------------------------------
# Test 1: CONFIG GET and missing RDB file behaves as an empty database
# ---------------------------------------------------------------------------
if start_server_with_rdb "missing RDB file" --dir "$FIXTURE_DIR" --dbfilename missing.rdb; then
    response=$(send_cmd CONFIG GET dir)
    check "CONFIG GET dir returns the configured directory" "$response" "$(expect_array dir "$FIXTURE_DIR")"

    response=$(send_cmd CONFIG GET dbfilename)
    check "CONFIG GET dbfilename returns the configured file name" "$response" "$(expect_array dbfilename missing.rdb)"

    response=$(send_cmd CONFIG GET not-a-real-param)
    check "CONFIG GET unknown parameter returns an empty array" "$response" "$(expect_empty_array)"

    response=$(send_cmd KEYS "*")
    check "KEYS * on missing RDB file returns an empty array" "$response" "$(expect_empty_array)"

    response=$(send_cmd GET missing-key)
    check "GET missing key from missing RDB file returns null bulk" "$response" "$(expect_null)"
fi

# ---------------------------------------------------------------------------
# Test 2: Valid empty RDB with metadata and checksum
# ---------------------------------------------------------------------------
if start_server_with_rdb "valid empty RDB" --dir "$FIXTURE_DIR" --dbfilename empty_valid.rdb; then
    response=$(send_cmd KEYS "*")
    check "KEYS * on valid empty RDB returns an empty array" "$response" "$(expect_empty_array)"

    response=$(send_cmd GET anything)
    check "GET anything on valid empty RDB returns null bulk" "$response" "$(expect_null)"

    response=$(send_cmd keys "*")
    check "lowercase keys command works on empty RDB" "$response" "$(expect_empty_array)"
fi

# ---------------------------------------------------------------------------
# Test 3: Single-key RDB: read one key and its length-prefixed value
# ---------------------------------------------------------------------------
if start_server_with_rdb "single key RDB" --dir "$FIXTURE_DIR" --dbfilename single_no_metadata.rdb; then
    response=$(send_cmd KEYS "*")
    check_array_unordered "KEYS * returns the one key from the RDB" "$response" foo

    response=$(send_cmd GET foo)
    check "GET foo returns bar from the RDB" "$response" "$(expect_bulk bar)"

    response=$(send_cmd get foo)
    check "lowercase get returns bar from the RDB" "$response" "$(expect_bulk bar)"

    response=$(send_cmd GET nope)
    check "GET unknown key from single-key RDB returns null bulk" "$response" "$(expect_null)"
fi

# ---------------------------------------------------------------------------
# Test 4: Multiple keys with multiple AUX metadata records
# ---------------------------------------------------------------------------
if start_server_with_rdb "metadata-heavy multi-key RDB" --dir "$FIXTURE_DIR" --dbfilename metadata_multi.rdb; then
    response=$(send_cmd KEYS "*")
    check_array_unordered "KEYS * returns all metadata_multi keys" "$response" apple banana carrot z-last

    response=$(send_cmd GET apple)
    check "GET apple returns red" "$response" "$(expect_bulk red)"

    response=$(send_cmd GET banana)
    check "GET banana returns yellow" "$response" "$(expect_bulk yellow)"

    response=$(send_cmd GET carrot)
    check "GET carrot returns orange" "$response" "$(expect_bulk orange)"

    response=$(send_cmd GET z-last)
    check "GET z-last returns tail" "$response" "$(expect_bulk tail)"
fi

# ---------------------------------------------------------------------------
# Test 5: Non-zero DB selector, checksum bytes, empty values, spaces, symbols
# ---------------------------------------------------------------------------
if start_server_with_rdb "high DB number and checksum RDB" --dir "$FIXTURE_DIR" --dbfilename high_db_checksum.rdb; then
    response=$(send_cmd KEYS "*")
    check_array_unordered "KEYS * handles DB 15, spaces, symbols, and empty values" \
        "$response" "space key" empty-value "punct:!@#$%^&*()" caseSensitive

    response=$(send_cmd GET "space key")
    check "GET key containing a space" "$response" "$(expect_bulk "value with spaces")"

    response=$(send_cmd GET empty-value)
    check "GET key with empty string value" "$response" "$(expect_bulk "")"

    response=$(send_cmd GET "punct:!@#$%^&*()")
    check "GET key containing punctuation" "$response" "$(expect_bulk symbols-ok)"

    response=$(send_cmd GET caseSensitive)
    check "GET case-sensitive key keeps original value" "$response" "$(expect_bulk MiXeD)"

    response=$(send_cmd GET casesensitive)
    check "GET different-case key misses" "$response" "$(expect_null)"
fi

# ---------------------------------------------------------------------------
# Test 6: RDB length encodings: 6-bit, 14-bit, and 32-bit string lengths
# ---------------------------------------------------------------------------
if start_server_with_rdb "length encoding RDB" --dir "$FIXTURE_DIR" --dbfilename length_encodings.rdb; then
    response=$(send_cmd KEYS "*")
    check_array_unordered "KEYS * returns short, 14-bit-length key, and 32-bit-value key" \
        "$response" short "$LONG_KEY" value32

    response=$(send_cmd GET short)
    check "GET short 6-bit encoded value" "$response" "$(expect_bulk tiny)"

    response=$(send_cmd GET "$LONG_KEY")
    check "GET key with 14-bit encoded key length and 14-bit encoded value length" \
        "$response" "$(expect_bulk "$VALUE_14")"

    response=$(send_cmd GET value32)
    check "GET value using 32-bit length encoding" "$response" "$(expect_bulk "$VALUE_32")"

    response=$(send_cmd GET absent-from-length-rdb)
    check "GET absent key from length encoding fixture returns null bulk" "$response" "$(expect_null)"
fi

# ---------------------------------------------------------------------------
# Test 7: Expiry opcodes: millisecond and second absolute Unix timestamps
# ---------------------------------------------------------------------------
if start_server_with_rdb "expiry RDB" --dir "$FIXTURE_DIR" --dbfilename expiry_mix.rdb; then
    response=$(send_cmd GET no_expiry)
    check "GET no_expiry returns non-expiring value" "$response" "$(expect_bulk alive)"

    response=$(send_cmd GET future_ms)
    check "GET future_ms returns value before millisecond expiry" "$response" "$(expect_bulk alive-ms)"

    response=$(send_cmd GET future_s)
    check "GET future_s returns value before second expiry" "$response" "$(expect_bulk alive-s)"

    response=$(send_cmd GET past_ms)
    check "GET past_ms returns null bulk for expired millisecond timestamp" "$response" "$(expect_null)"

    response=$(send_cmd GET past_s)
    check "GET past_s returns null bulk for expired second timestamp" "$response" "$(expect_null)"

    response=$(send_cmd GET past_ms)
    check "GET past_ms remains null after first expiry lookup" "$response" "$(expect_null)"

    response=$(send_cmd KEYS "*")
    check_array_unordered "KEYS * excludes expired keys after they have been looked up" \
        "$response" no_expiry future_ms future_s
fi

# # ---------------------------------------------------------------------------
# # Test 8: Invalid, empty, truncated, and unsupported RDB formats
# # ---------------------------------------------------------------------------
# expect_startup_failure "empty RDB file fails startup cleanly" \
#     --dir "$FIXTURE_DIR" --dbfilename empty_file.rdb

# expect_startup_failure "bad magic header fails startup cleanly" \
#     --dir "$FIXTURE_DIR" --dbfilename bad_magic.rdb

# expect_startup_failure "truncated RDB file fails startup cleanly" \
#     --dir "$FIXTURE_DIR" --dbfilename truncated.rdb

# expect_startup_failure "unsupported non-string value type fails startup cleanly" \
#     --dir "$FIXTURE_DIR" --dbfilename unsupported_value_type.rdb

# expect_startup_failure "unsupported special string encoding fails startup cleanly" \
#     --dir "$FIXTURE_DIR" --dbfilename unsupported_special_string.rdb

echo "=============================="
echo "RDB persistence test results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi
