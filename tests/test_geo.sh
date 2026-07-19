#!/bin/bash
# Verify GEO commands: GEOADD, GEOPOS, GEODIST, and GEOSEARCH.

source "$(dirname "$0")/helpers.sh"

echo "=== Stage: GEO commands (GEOADD/GEOPOS/GEODIST/GEOSEARCH) ==="

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Low-level helpers
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
    timeout 3 nc -q 1 127.0.0.1 6379 < "$tmp" 2>/dev/null
    rm -f "$tmp"
}

send_raw() {
    local payload="$1"
    printf '%b' "$payload" | timeout 3 nc -q 1 127.0.0.1 6379 2>/dev/null
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

check_is_error() {
    local label="$1" response="$2"
    case "$response" in
        -ERR*|-WRONGTYPE*)
            pass "$label"
            PASS_COUNT=$((PASS_COUNT + 1))
            ;;
        *)
            fail "$label"
            fail "  expected : RESP error"
            fail "  got      : $(printf '%s' "$response" | cat -A)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            ;;
    esac
}

check_error_mentions() {
    local label="$1" response="$2"
    shift 2

    case "$response" in
        -ERR*|-WRONGTYPE*) ;;
        *)
            fail "$label"
            fail "  expected : RESP error"
            fail "  got      : $(printf '%s' "$response" | cat -A)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            return
            ;;
    esac

    local lower missing=0 word
    lower=$(printf '%s' "$response" | tr '[:upper:]' '[:lower:]')
    for word in "$@"; do
        case "$lower" in
            *"$word"*) ;;
            *) missing=1 ;;
        esac
    done

    if [ "$missing" -eq 0 ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected error mentioning: $*"
        fail "  got                    : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_no_crash_response() {
    local label="$1" response="$2"
    if [ -n "$response" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected : any RESP response"
        fail "  got      : empty response"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

expect_int()         { printf ':%d\r' "$1"; }
expect_bulk()        { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_null_bulk()   { printf '$-1\r'; }
expect_empty_array() { printf '*0\r'; }
expect_type()        { printf '+%s\r' "$1"; }

expect_array() {
    if [ "$#" -eq 0 ]; then
        expect_empty_array
        return
    fi

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

expect_null_arrays() {
    local count="$1" i
    if [ "$count" -eq 0 ]; then
        expect_empty_array
        return
    fi

    printf '*%d\r\n' "$count"
    for ((i = 1; i <= count; i++)); do
        if [ "$i" -eq "$count" ]; then
            printf '*-1\r'
        else
            printf '*-1\r\n'
        fi
    done
}

bulk_payloads() {
    local response="$1"
    printf '%s\n' "$response" | tr -d '\r' | awk '
        prev_is_bulk { print; prev_is_bulk = 0; next }
        /^\$[0-9]+$/ { prev_is_bulk = 1; next }
        { prev_is_bulk = 0 }
    '
}

array_header_count() {
    local response="$1"
    printf '%s\n' "$response" | tr -d '\r' | sed -n '1s/^\*\([0-9][0-9]*\)$/\1/p'
}

float_close() {
    local actual="$1" expected="$2" epsilon="$3"
    awk -v a="$actual" -v e="$expected" -v eps="$epsilon" '
        BEGIN {
            d = a - e
            if (d < 0) d = -d
            exit(d <= eps ? 0 : 1)
        }
    '
}

check_float_bulk_close() {
    local label="$1" response="$2" expected="$3" epsilon="$4"
    local actual
    actual=$(bulk_payloads "$response" | sed -n '1p')

    if [ -n "$actual" ] && float_close "$actual" "$expected" "$epsilon"; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected : bulk float close to $expected"
        fail "  got      : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_geopos_close_one() {
    local label="$1" response="$2" expected_lon="$3" expected_lat="$4"
    local top lon lat payload_count

    top=$(array_header_count "$response")
    lon=$(bulk_payloads "$response" | sed -n '1p')
    lat=$(bulk_payloads "$response" | sed -n '2p')
    payload_count=$(bulk_payloads "$response" | wc -l | tr -d ' ')

    if [ "$top" = "1" ] &&
       [ "$payload_count" = "2" ] &&
       float_close "$lon" "$expected_lon" "0.0000015" &&
       float_close "$lat" "$expected_lat" "0.0000015"; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected : one position close to [$expected_lon, $expected_lat]"
        fail "  got      : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_geopos_count_and_floats() {
    local label="$1" response="$2" expected_count="$3"
    local top payload_count

    top=$(array_header_count "$response")
    payload_count=$(bulk_payloads "$response" | wc -l | tr -d ' ')

    if [ "$top" = "$expected_count" ] && [ "$payload_count" -eq $((expected_count * 2)) ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected : $expected_count positions with longitude/latitude bulk strings"
        fail "  got      : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_unordered_array() {
    local label="$1" response="$2"
    shift 2
    local expected_count="$#" top actual_sorted expected_sorted

    top=$(array_header_count "$response")
    actual_sorted=$(bulk_payloads "$response" | sort | tr '\n' '|')
    expected_sorted=$(printf '%s\n' "$@" | sort | tr '\n' '|')

    if [ "$top" = "$expected_count" ] && [ "$actual_sorted" = "$expected_sorted" ]; then
        pass "$label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$label"
        fail "  expected members : $*"
        fail "  got              : $(printf '%s' "$response" | cat -A)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# ---------------------------------------------------------------------------
# Test 1: GEOADD response and basic storage
# ---------------------------------------------------------------------------

response=$(send_cmd GEOADD geo:basic 11.5030378 48.164271 Munich)
check "GEOADD adds Munich -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd TYPE geo:basic)
check "GEOADD creates a zset-backed key" "$response" "$(expect_type zset)"

response=$(send_cmd ZRANGE geo:basic 0 -1)
check "ZRANGE after one GEOADD -> [Munich]" "$response" "$(expect_array Munich)"

response=$(send_cmd GEOADD geo:basic 11.5030378 48.164271 Munich)
check "GEOADD existing member updates score -> :0" "$response" "$(expect_int 0)"

response=$(send_cmd ZCARD geo:basic)
check "ZCARD remains 1 after GEOADD update" "$response" "$(expect_int 1)"

response=$(send_cmd geoadd geo:case -0.127758 51.507351 London)
check "geoadd lowercase command works -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd GeOaDd geo:case 2.2944692 48.8584625 Paris)
check "GeOaDd mixed-case command works -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd ZRANGE geo:case 0 -1)
check "ZRANGE sees lowercase/mixed-case GEOADD members" "$response" "$(expect_array London Paris)"

# ---------------------------------------------------------------------------
# Test 2: Coordinate validation, boundaries, and empty arguments
# ---------------------------------------------------------------------------

response=$(send_cmd GEOADD geo:bounds -180 -85.05112878 min_corner)
check "GEOADD accepts minimum longitude/latitude boundary" "$response" "$(expect_int 1)"

response=$(send_cmd GEOADD geo:bounds 180 85.05112878 max_corner)
check "GEOADD accepts maximum longitude/latitude boundary" "$response" "$(expect_int 1)"

response=$(send_cmd GEOADD geo:invalid 181 0 too_far_east)
check_error_mentions "GEOADD rejects longitude > 180" "$response" longitude

response=$(send_cmd GEOADD geo:invalid -180.000001 0 too_far_west)
check_error_mentions "GEOADD rejects longitude < -180" "$response" longitude

response=$(send_cmd GEOADD geo:invalid 0 85.05112879 too_far_north)
check_error_mentions "GEOADD rejects latitude above Web Mercator max" "$response" latitude

response=$(send_cmd GEOADD geo:invalid 0 -85.05112879 too_far_south)
check_error_mentions "GEOADD rejects latitude below Web Mercator min" "$response" latitude

response=$(send_cmd GEOADD geo:invalid 200 100 both_bad)
check_error_mentions "GEOADD rejects invalid longitude and latitude together" "$response" longitude latitude

response=$(send_cmd GEOADD geo:invalid abc 0 nonnumeric_lon)
check_error_mentions "GEOADD rejects non-numeric longitude" "$response" longitude

response=$(send_cmd GEOADD geo:invalid 0 abc nonnumeric_lat)
check_error_mentions "GEOADD rejects non-numeric latitude" "$response" latitude

response=$(send_cmd GEOADD geo:invalid "" 0 empty_lon)
check_is_error "GEOADD rejects empty longitude bulk string" "$response"

response=$(send_cmd GEOADD geo:invalid 0 "" empty_lat)
check_is_error "GEOADD rejects empty latitude bulk string" "$response"

response=$(send_cmd GEOADD)
check_is_error "GEOADD with no arguments returns an error" "$response"

response=$(send_cmd GEOADD geo:arity 1 2)
check_is_error "GEOADD with missing member returns an error" "$response"

response=$(send_cmd GEOADD geo:arity 1 2 member extra)
check_is_error "GEOADD with extra argument returns an error" "$response"

# ---------------------------------------------------------------------------
# Test 3: Score calculation through ZSCORE
# ---------------------------------------------------------------------------

response=$(send_cmd GEOADD geo:scores 2.2944692 48.8584625 Paris)
check "GEOADD Paris for score fixture -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd ZSCORE geo:scores Paris)
check "ZSCORE Paris matches Redis geohash score" "$response" "$(expect_bulk 3663832614298053)"

response=$(send_cmd GEOADD geo:scores -0.127758 51.507351 London)
check "GEOADD London for score ordering -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd GEOADD geo:scores 11.5030378 48.164271 Munich)
check "GEOADD Munich for score ordering -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd GEOADD geo:scores 139.6917 35.6895 Tokyo)
check "GEOADD Tokyo for score ordering -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd ZRANGE geo:scores 0 -1)
check_unordered_array "ZRANGE geo:scores contains all GEOADD members" "$response" Paris London Munich Tokyo

response=$(send_cmd ZSCORE geo:scores missing_member)
check "ZSCORE missing GEO member -> null bulk" "$response" "$(expect_null_bulk)"

# ---------------------------------------------------------------------------
# Test 4: GEOPOS missing keys, missing members, and decoded coordinates
# ---------------------------------------------------------------------------

response=$(send_cmd GEOPOS geo:scores Paris)
check_geopos_close_one "GEOPOS Paris decodes stored score" "$response" 2.294471561908722 48.85846255040141

response=$(send_cmd GEOPOS geo:scores London Munich Tokyo)
check_geopos_count_and_floats "GEOPOS multiple existing members returns 3 coordinate pairs" "$response" 3

response=$(send_cmd GEOPOS geo:scores missing_member)
check "GEOPOS missing member returns a null array" "$response" "$(expect_null_arrays 1)"

response=$(send_cmd GEOPOS geo:does-not-exist Paris London)
check "GEOPOS missing key returns one null array per member" "$response" "$(expect_null_arrays 2)"

response=$(send_cmd GEOPOS geo:scores Paris missing_member Munich)
check_no_crash_response "GEOPOS mixed existing/missing members returns a RESP response" "$response"

response=$(send_cmd GEOPOS)
check_is_error "GEOPOS with no arguments returns an error" "$response"

response=$(send_cmd GEOPOS geo:scores)
check_is_error "GEOPOS with no members returns an error" "$response"

# ---------------------------------------------------------------------------
# Test 5: Decode coordinates from scores inserted with ZADD
# ---------------------------------------------------------------------------

response=$(send_cmd ZADD geo:decode 3663832614298053 Foo)
check "ZADD decode fixture Foo -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd ZADD geo:decode 3876464048901851 Bar)
check "ZADD decode fixture Bar -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd ZADD geo:decode 3468915414364476 Baz)
check "ZADD decode fixture Baz -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd ZADD geo:decode 3781709020344510 Caz)
check "ZADD decode fixture Caz -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd GEOPOS geo:decode Foo)
check_geopos_close_one "GEOPOS decodes score 3663832614298053" "$response" 2.294471561908722 48.85846255040141

response=$(send_cmd GEOPOS geo:decode Foo Bar Baz Caz)
check_geopos_count_and_floats "GEOPOS decodes four ZADD score fixtures" "$response" 4

# ---------------------------------------------------------------------------
# Test 6: GEODIST distances and missing members
# ---------------------------------------------------------------------------

response=$(send_cmd GEODIST geo:scores Munich Paris)
check_float_bulk_close "GEODIST Munich Paris in meters" "$response" 682477.7582 0.0002

response=$(send_cmd GEODIST geo:scores Paris Munich)
check_float_bulk_close "GEODIST Paris Munich is symmetric" "$response" 682477.7582 0.0002

response=$(send_cmd GEODIST geo:scores Paris Paris)
check_float_bulk_close "GEODIST same member is zero" "$response" 0 0.0002

response=$(send_cmd GEODIST geo:scores Paris missing_member)
check "GEODIST missing member -> null bulk" "$response" "$(expect_null_bulk)"

response=$(send_cmd GEODIST geo:missing Paris Munich)
check "GEODIST missing key -> null bulk" "$response" "$(expect_null_bulk)"

response=$(send_cmd GEODIST)
check_is_error "GEODIST with no arguments returns an error" "$response"

response=$(send_cmd GEODIST geo:scores Paris)
check_is_error "GEODIST with one member returns an error" "$response"

# ---------------------------------------------------------------------------
# Test 7: GEOSEARCH FROMLONLAT/BYRADIUS with meters and other units
# ---------------------------------------------------------------------------

response=$(send_cmd GEOADD geo:search 11.5030378 48.164271 Munich)
check "GEOADD search member Munich -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd GEOADD geo:search 2.2944692 48.8584625 Paris)
check "GEOADD search member Paris -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd GEOADD geo:search -0.0884948 51.506479 London)
check "GEOADD search member London -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd GEOADD geo:search -74.0445 40.6892 Liberty)
check "GEOADD search member Liberty -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd GEOADD geo:search 151.2153 -33.8568 Sydney)
check "GEOADD search member Sydney -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd GEOSEARCH geo:search FROMLONLAT 2 48 BYRADIUS 100000 m)
check_unordered_array "GEOSEARCH 100000m around 2,48 -> Paris" "$response" Paris

response=$(send_cmd GEOSEARCH geo:search FROMLONLAT 2 48 BYRADIUS 500000 m)
check_unordered_array "GEOSEARCH 500000m around 2,48 -> Paris and London" "$response" Paris London

response=$(send_cmd GEOSEARCH geo:search FROMLONLAT 11 50 BYRADIUS 300000 m)
check_unordered_array "GEOSEARCH 300000m around 11,50 -> Munich" "$response" Munich

response=$(send_cmd GEOSEARCH geo:search FROMLONLAT -74 40.7 BYRADIUS 100 km)
check_unordered_array "GEOSEARCH 100km around New York harbor -> Liberty" "$response" Liberty

response=$(send_cmd GEOSEARCH geo:search FROMLONLAT 151.2 -33.85 BYRADIUS 20 km)
check_unordered_array "GEOSEARCH 20km around Sydney -> Sydney" "$response" Sydney

response=$(send_cmd GEOSEARCH geo:search FROMLONLAT 0 0 BYRADIUS 1000 m)
check "GEOSEARCH around empty ocean area -> empty array" "$response" "$(expect_empty_array)"

response=$(send_cmd GEOSEARCH geo:search FROMLONLAT 2 48 BYRADIUS 328084 ft)
check_unordered_array "GEOSEARCH 328084ft around 2,48 -> Paris" "$response" Paris

response=$(send_cmd GEOSEARCH geo:search FROMLONLAT 2 48 BYRADIUS 320 mi)
check_unordered_array "GEOSEARCH 320mi around 2,48 -> Paris and London" "$response" Paris London

response=$(send_cmd GEOSEARCH geo:search)
check_is_error "GEOSEARCH missing options returns an error" "$response"

response=$(send_cmd GEOSEARCH geo:search FROMLONLAT x 48 BYRADIUS 1000 m)
check_is_error "GEOSEARCH non-numeric center longitude returns an error" "$response"

response=$(send_cmd GEOSEARCH geo:search FROMLONLAT 2 y BYRADIUS 1000 m)
check_is_error "GEOSEARCH non-numeric center latitude returns an error" "$response"

response=$(send_cmd GEOSEARCH geo:search FROMLONLAT 2 48 BYRADIUS bad m)
check_is_error "GEOSEARCH non-numeric radius returns an error" "$response"

response=$(send_cmd GEOSEARCH geo:search FROMLONLAT 2 48 BYRADIUS 100 parsecs)
check_is_error "GEOSEARCH invalid unit returns an error" "$response"

# ---------------------------------------------------------------------------
# Test 8: Wrong-type and raw malformed/empty RESP cases
# ---------------------------------------------------------------------------

send_cmd SET geo:string-key value >/dev/null

response=$(send_cmd GEOADD geo:string-key 1 2 member)
check_is_error "GEOADD against string key returns an error" "$response"

response=$(send_cmd GEOPOS geo:string-key member)
check_no_crash_response "GEOPOS against string key returns a RESP response" "$response"

response=$(send_raw '*2\r\n$6\r\nGEOADD\r\n$0\r\n\r\n')
check_is_error "Raw GEOADD with only empty key returns an error" "$response"

# Keep missing-key GEOSEARCH last because buggy implementations may crash here.
response=$(send_cmd GEOSEARCH geo:missing-search FROMLONLAT 2 48 BYRADIUS 100 m)
check_no_crash_response "GEOSEARCH missing key should return a RESP response" "$response"

stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "GEO command tests passed."
else
    exit 1
fi
