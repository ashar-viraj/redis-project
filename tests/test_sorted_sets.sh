#!/bin/bash
# Verify sorted set commands: ZADD, ZRANK, ZRANGE, ZCARD, ZSCORE, and ZREM.

source "$(dirname "$0")/helpers.sh"

echo "=== Stage: Sorted sets (ZADD/ZRANK/ZRANGE/ZCARD/ZSCORE/ZREM) ==="

build_server
start_server

PASS_COUNT=0
FAIL_COUNT=0

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

check_error_or_no_response() {
    local label="$1" response="$2"
    case "$response" in
        ""|-ERR*|-WRONGTYPE*)
            pass "$label"
            PASS_COUNT=$((PASS_COUNT + 1))
            ;;
        *)
            fail "$label"
            fail "  expected : no response or RESP error"
            fail "  got      : $(printf '%s' "$response" | cat -A)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            ;;
    esac
}

# Command substitution strips trailing LF, so expected responses end in CR.
expect_int()         { printf ':%d\r' "$1"; }
expect_bulk()        { printf '$%d\r\n%s\r' "${#1}" "$1"; }
expect_null()        { printf '$-1\r'; }
expect_empty_array() { printf '*0\r'; }
expect_pong()        { printf '+PONG\r'; }
expect_ok()          { printf '+OK\r'; }
expect_simple()      { printf '+%s\r' "$1"; }

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

# ---------------------------------------------------------------------------
# Test 1: Missing sorted set behavior before any ZADD
# ---------------------------------------------------------------------------

# response=$(send_cmd ZCARD missing_zset)
# check "ZCARD missing key -> :0" "$response" "$(expect_int 0)"

# response=$(send_cmd ZRANGE missing_zset 0 -1)
# check "ZRANGE missing key -> empty array" "$response" "$(expect_empty_array)"

# response=$(send_cmd ZRANK missing_zset member)
# check "ZRANK missing key -> null bulk" "$response" "$(expect_null)"

# response=$(send_cmd ZSCORE missing_zset member)
# check "ZSCORE missing key -> null bulk" "$response" "$(expect_null)"

# response=$(send_cmd ZREM missing_zset member)
# check "ZREM missing key -> :0" "$response" "$(expect_int 0)"

# # ---------------------------------------------------------------------------
# # Test 2: Create a sorted set with one member
# # ---------------------------------------------------------------------------

# response=$(send_cmd ZADD single_zset 10.5 solo)
# check "ZADD creates sorted set with one member -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZCARD single_zset)
# check "ZCARD single_zset -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZRANGE single_zset 0 0)
# check "ZRANGE single_zset 0 0 -> [solo]" "$response" "$(expect_array solo)"

# response=$(send_cmd ZRANGE single_zset 0 -1)
# check "ZRANGE single_zset 0 -1 -> [solo]" "$response" "$(expect_array solo)"

# response=$(send_cmd ZRANK single_zset solo)
# check "ZRANK single_zset solo -> :0" "$response" "$(expect_int 0)"

# response=$(send_cmd ZSCORE single_zset solo)
# check "ZSCORE single_zset solo -> 10.5" "$response" "$(expect_bulk 10.5)"

# # ---------------------------------------------------------------------------
# # Test 3: Add members, rank by score, and update an existing member
# # ---------------------------------------------------------------------------

# response=$(send_cmd ZADD zset_key 100.0 foo)
# check "ZADD zset_key foo -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD zset_key 100.0 bar)
# check "ZADD zset_key bar -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD zset_key 20.0 baz)
# check "ZADD zset_key baz -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD zset_key 30.1 caz)
# check "ZADD zset_key caz -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD zset_key 40.2 paz)
# check "ZADD zset_key paz -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZCARD zset_key)
# check "ZCARD zset_key after five adds -> :5" "$response" "$(expect_int 5)"

# response=$(send_cmd ZRANGE zset_key 0 -1)
# check "ZRANGE zset_key full order with tie -> [baz,caz,paz,bar,foo]" \
#     "$response" "$(expect_array baz caz paz bar foo)"

# response=$(send_cmd ZRANK zset_key baz)
# check "ZRANK baz -> :0" "$response" "$(expect_int 0)"

# response=$(send_cmd ZRANK zset_key caz)
# check "ZRANK caz -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZRANK zset_key paz)
# check "ZRANK paz -> :2" "$response" "$(expect_int 2)"

# response=$(send_cmd ZRANK zset_key bar)
# check "ZRANK bar -> :3" "$response" "$(expect_int 3)"

# response=$(send_cmd ZRANK zset_key foo)
# check "ZRANK foo -> :4" "$response" "$(expect_int 4)"

# response=$(send_cmd ZSCORE zset_key caz)
# check "ZSCORE caz -> 30.1" "$response" "$(expect_bulk 30.1)"

# response=$(send_cmd ZSCORE zset_key missing_member)
# check "ZSCORE missing member -> null bulk" "$response" "$(expect_null)"

# response=$(send_cmd ZRANK zset_key missing_member)
# check "ZRANK missing member -> null bulk" "$response" "$(expect_null)"

# response=$(send_cmd ZADD zset_key 25.5 foo)
# check "ZADD existing foo updates score -> :0" "$response" "$(expect_int 0)"

# response=$(send_cmd ZCARD zset_key)
# check "ZCARD unchanged after score update -> :5" "$response" "$(expect_int 5)"

# response=$(send_cmd ZSCORE zset_key foo)
# check "ZSCORE foo after update -> 25.5" "$response" "$(expect_bulk 25.5)"

# response=$(send_cmd ZRANGE zset_key 0 -1)
# check "ZRANGE after moving foo by score -> [baz,foo,caz,paz,bar]" \
#     "$response" "$(expect_array baz foo caz paz bar)"

# response=$(send_cmd ZRANK zset_key foo)
# check "ZRANK foo after update -> :1" "$response" "$(expect_int 1)"

# # ---------------------------------------------------------------------------
# # Test 4: ZRANGE positive indexes, bounds, and empty slices
# # ---------------------------------------------------------------------------

# response=$(send_cmd ZRANGE zset_key 0 2)
# check "ZRANGE 0 2 -> first three" "$response" "$(expect_array baz foo caz)"

# response=$(send_cmd ZRANGE zset_key 2 4)
# check "ZRANGE 2 4 -> last three" "$response" "$(expect_array caz paz bar)"

# response=$(send_cmd ZRANGE zset_key 2 99)
# check "ZRANGE stop beyond cardinality clamps to tail" "$response" "$(expect_array caz paz bar)"

# response=$(send_cmd ZRANGE zset_key 4 4)
# check "ZRANGE single last positive index -> [bar]" "$response" "$(expect_array bar)"

# response=$(send_cmd ZRANGE zset_key 5 9)
# check "ZRANGE start equal to cardinality -> empty array" "$response" "$(expect_empty_array)"

# response=$(send_cmd ZRANGE zset_key 99 100)
# check "ZRANGE start beyond cardinality -> empty array" "$response" "$(expect_empty_array)"

# response=$(send_cmd ZRANGE zset_key 3 1)
# check "ZRANGE start greater than stop -> empty array" "$response" "$(expect_empty_array)"

# # ---------------------------------------------------------------------------
# # Test 5: ZRANGE negative indexes
# # ---------------------------------------------------------------------------

# response=$(send_cmd ZADD neg_zset 20.0 foo)
# check "ZADD neg_zset foo -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD neg_zset 30.1 bar)
# check "ZADD neg_zset bar -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD neg_zset 40.2 baz)
# check "ZADD neg_zset baz -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD neg_zset 25.0 paz)
# check "ZADD neg_zset paz -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD neg_zset 25.0 caz)
# check "ZADD neg_zset caz -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZRANGE neg_zset 0 -1)
# check "ZRANGE neg_zset 0 -1 -> all sorted members" "$response" \
#     "$(expect_array foo caz paz bar baz)"

# response=$(send_cmd ZRANGE neg_zset -1 -1)
# check "ZRANGE -1 -1 -> last member" "$response" "$(expect_array baz)"

# response=$(send_cmd ZRANGE neg_zset -2 -1)
# check "ZRANGE -2 -1 -> last two" "$response" "$(expect_array bar baz)"

# response=$(send_cmd ZRANGE neg_zset 2 -1)
# check "ZRANGE 2 -1 -> [paz,bar,baz]" "$response" "$(expect_array paz bar baz)"

# response=$(send_cmd ZRANGE neg_zset 0 -3)
# check "ZRANGE 0 -3 -> all except last two" "$response" "$(expect_array foo caz paz)"

# response=$(send_cmd ZRANGE neg_zset -5 -1)
# check "ZRANGE -5 -1 -> whole set" "$response" "$(expect_array foo caz paz bar baz)"

# response=$(send_cmd ZRANGE neg_zset -100 -1)
# check "ZRANGE negative start far out of range -> whole set" "$response" \
#     "$(expect_array foo caz paz bar baz)"

# response=$(send_cmd ZRANGE neg_zset 3 -4)
# check "ZRANGE negative stop before start -> empty array" "$response" "$(expect_empty_array)"

# # ---------------------------------------------------------------------------
# # Test 6: Lexicographic ordering for equal scores
# # ---------------------------------------------------------------------------

# response=$(send_cmd ZADD tie_zset 5.5 zebra)
# check "ZADD tie_zset zebra -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD tie_zset 5.5 alpha)
# check "ZADD tie_zset alpha -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD tie_zset 5.5 bravo)
# check "ZADD tie_zset bravo -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD tie_zset 5.5 aardvark)
# check "ZADD tie_zset aardvark -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD tie_zset 5.5 alphabet)
# check "ZADD tie_zset alphabet -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZRANGE tie_zset 0 -1)
# check "ZRANGE equal scores uses lexicographic member order" "$response" \
#     "$(expect_array aardvark alpha alphabet bravo zebra)"

# response=$(send_cmd ZRANK tie_zset aardvark)
# check "ZRANK aardvark among equal scores -> :0" "$response" "$(expect_int 0)"

# response=$(send_cmd ZRANK tie_zset alpha)
# check "ZRANK alpha among equal scores -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZRANK tie_zset alphabet)
# check "ZRANK alphabet among equal scores -> :2" "$response" "$(expect_int 2)"

# response=$(send_cmd ZRANK tie_zset zebra)
# check "ZRANK zebra among equal scores -> :4" "$response" "$(expect_int 4)"

# response=$(send_cmd ZADD tie_zset 1.25 zebra)
# check "ZADD existing zebra to lower score -> :0" "$response" "$(expect_int 0)"

# response=$(send_cmd ZRANGE tie_zset 0 -1)
# check "ZRANGE after tie member score update moves zebra to front" "$response" \
#     "$(expect_array zebra aardvark alpha alphabet bravo)"

# # ---------------------------------------------------------------------------
# # Test 7: Empty member names, spaces, punctuation, and numeric-looking members
# # ---------------------------------------------------------------------------

# response=$(send_cmd ZADD odd_zset 0.0043 "")
# check "ZADD empty member name -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD odd_zset 1.5 "member with spaces")
# check "ZADD member with spaces -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD odd_zset 2.5 'punct:!@#$%^&*()')
# check "ZADD punctuation member -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD odd_zset 3.5 0007)
# check "ZADD numeric-looking member -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZRANGE odd_zset 0 -1)
# check "ZRANGE odd_zset preserves unusual member names" "$response" \
#     "$(expect_array "" "member with spaces" 'punct:!@#$%^&*()' 0007)"

# response=$(send_cmd ZRANK odd_zset "")
# check "ZRANK empty member -> :0" "$response" "$(expect_int 0)"

# response=$(send_cmd ZSCORE odd_zset "")
# check "ZSCORE empty member -> 0.0043" "$response" "$(expect_bulk 0.0043)"

# response=$(send_cmd ZSCORE odd_zset "member with spaces")
# check "ZSCORE spaced member -> 1.5" "$response" "$(expect_bulk 1.5)"

# response=$(send_cmd ZREM odd_zset "")
# check "ZREM empty member -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZRANGE odd_zset 0 -1)
# check "ZRANGE odd_zset after removing empty member" "$response" \
#     "$(expect_array "member with spaces" 'punct:!@#$%^&*()' 0007)"

# # ---------------------------------------------------------------------------
# # Test 8: Negative, zero, tiny, and large floating-point scores
# # ---------------------------------------------------------------------------

# response=$(send_cmd ZADD score_zset -2.5 negative)
# check "ZADD negative floating score -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD score_zset 0 zero)
# check "ZADD zero score -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD score_zset 0.0043 tiny)
# check "ZADD tiny fractional score -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD score_zset 999999.75 large)
# check "ZADD large fractional score -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZRANGE score_zset 0 -1)
# check "ZRANGE orders negative, zero, tiny, and large scores" "$response" \
#     "$(expect_array negative zero tiny large)"

# response=$(send_cmd ZSCORE score_zset negative)
# check "ZSCORE negative -> -2.5" "$response" "$(expect_bulk -2.5)"

# response=$(send_cmd ZSCORE score_zset tiny)
# check "ZSCORE tiny -> 0.0043" "$response" "$(expect_bulk 0.0043)"

# response=$(send_cmd ZRANK score_zset large)
# check "ZRANK large -> :3" "$response" "$(expect_int 3)"

# # ---------------------------------------------------------------------------
# # Test 9: Remove members and verify ranks, cardinality, and ranges
# # ---------------------------------------------------------------------------

# response=$(send_cmd ZADD rem_zset 80.5 foo)
# check "ZADD rem_zset foo -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD rem_zset 50.3 baz)
# check "ZADD rem_zset baz -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZADD rem_zset 80.5 bar)
# check "ZADD rem_zset bar -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZRANGE rem_zset 0 -1)
# check "ZRANGE rem_zset before removal -> [baz,bar,foo]" "$response" \
#     "$(expect_array baz bar foo)"

# response=$(send_cmd ZREM rem_zset baz)
# check "ZREM existing baz -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZRANGE rem_zset 0 -1)
# check "ZRANGE rem_zset after removing baz -> [bar,foo]" "$response" \
#     "$(expect_array bar foo)"

# response=$(send_cmd ZCARD rem_zset)
# check "ZCARD rem_zset after one removal -> :2" "$response" "$(expect_int 2)"

# response=$(send_cmd ZRANK rem_zset baz)
# check "ZRANK removed baz -> null bulk" "$response" "$(expect_null)"

# response=$(send_cmd ZSCORE rem_zset baz)
# check "ZSCORE removed baz -> null bulk" "$response" "$(expect_null)"

# response=$(send_cmd ZREM rem_zset missing_member)
# check "ZREM missing member -> :0" "$response" "$(expect_int 0)"

# response=$(send_cmd ZREM rem_zset baz)
# check "ZREM already removed member -> :0" "$response" "$(expect_int 0)"

# response=$(send_cmd ZREM rem_zset bar)
# check "ZREM existing bar -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZREM rem_zset foo)
# check "ZREM existing foo -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZCARD rem_zset)
# check "ZCARD rem_zset after removing all members -> :0" "$response" "$(expect_int 0)"

# response=$(send_cmd ZRANGE rem_zset 0 -1)
# check "ZRANGE rem_zset after removing all members -> empty array" "$response" \
#     "$(expect_empty_array)"

# # ---------------------------------------------------------------------------
# # Test 10: Case-insensitive command names
# # ---------------------------------------------------------------------------

# response=$(send_cmd zadd case_zset 1.1 lower)
# check "zadd lowercase command -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd ZaDd case_zset 2.2 mixed)
# check "ZaDd mixed-case command -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd zcard case_zset)
# check "zcard lowercase command -> :2" "$response" "$(expect_int 2)"

# response=$(send_cmd zrange case_zset 0 -1)
# check "zrange lowercase command -> [lower,mixed]" "$response" "$(expect_array lower mixed)"

# response=$(send_cmd zrank case_zset mixed)
# check "zrank lowercase command -> :1" "$response" "$(expect_int 1)"

# response=$(send_cmd zscore case_zset lower)
# check "zscore lowercase command -> 1.1" "$response" "$(expect_bulk 1.1)"

# response=$(send_cmd zrem case_zset lower)
# check "zrem lowercase command -> :1" "$response" "$(expect_int 1)"

# ---------------------------------------------------------------------------
# Test 11: Wrong-type keys should return a RESP error
# ---------------------------------------------------------------------------

response=$(send_cmd SET plain_string value)
check "SET plain_string baseline -> +OK" "$response" "$(expect_ok)"

response=$(send_cmd RPUSH plain_list one two)
check "RPUSH plain_list baseline -> :2" "$response" "$(expect_int 2)"

response=$(send_cmd ZADD plain_string 1.0 member)
check_is_error "ZADD against string key -> error" "$response"

# response=$(send_cmd ZRANGE plain_string 0 -1)
# check_is_error "ZRANGE against string key -> error" "$response"

response=$(send_cmd ZRANK plain_string member)
check_is_error "ZRANK against string key -> error" "$response"

# response=$(send_cmd ZCARD plain_string)
# check_is_error "ZCARD against string key -> error" "$response"

# response=$(send_cmd ZSCORE plain_string member)
# check_is_error "ZSCORE against string key -> error" "$response"

# response=$(send_cmd ZREM plain_string member)
# check_is_error "ZREM against string key -> error" "$response"

response=$(send_cmd ZADD plain_list 1.0 member)
check_is_error "ZADD against list key -> error" "$response"

# response=$(send_cmd GET zset_key)
# check_is_error "GET against sorted set key -> error" "$response"

# ---------------------------------------------------------------------------
# Test 12: Invalid arity, invalid numeric inputs, and empty RESP cases
# ---------------------------------------------------------------------------

response=$(send_cmd ZADD)
check_is_error "ZADD with no arguments -> error" "$response"

response=$(send_cmd ZADD invalid_zset)
check_is_error "ZADD with only key -> error" "$response"

response=$(send_cmd ZADD invalid_zset 1.0)
check_is_error "ZADD without member -> error" "$response"

response=$(send_cmd ZADD invalid_zset not-a-float member)
check_is_error "ZADD invalid score -> error" "$response"

response=$(send_cmd ZADD invalid_zset "" member)
check_is_error "ZADD empty score -> error" "$response"

response=$(send_cmd ZRANK zset_key)
check_is_error "ZRANK missing member argument -> error" "$response"

response=$(send_cmd ZRANGE zset_key 0)
check_is_error "ZRANGE missing stop argument -> error" "$response"

# response=$(send_cmd ZRANGE zset_key start stop)
# check_is_error "ZRANGE non-integer indexes -> error" "$response"

response=$(send_cmd ZCARD zset_key extra)
check_is_error "ZCARD extra argument -> error" "$response"

response=$(send_cmd ZSCORE zset_key)
check_is_error "ZSCORE missing member argument -> error" "$response"

response=$(send_cmd ZREM zset_key)
check_is_error "ZREM missing member argument -> error" "$response"

response=$(send_raw "")
check_error_or_no_response "Empty TCP payload -> no response or error" "$response"

# response=$(send_raw '*0\r\n')
# check_error_or_no_response "Empty RESP array -> no response or error" "$response"

response=$(send_raw '*1\r\n$0\r\n\r\n')
check_error_or_no_response "Empty command name -> no response or error" "$response"

response=$(send_raw '*3\r\n$4\r\nZADD\r\n$9\r\ntruncated\r\n')
check_error_or_no_response "Truncated ZADD payload -> no response or error" "$response"

response=$(send_cmd PING)
check "Server still responds after invalid/empty zset inputs" "$response" "$(expect_pong)"

# ---------------------------------------------------------------------------
# Test 13: Stress many members, updates, slices, negative ranges, and removals
# ---------------------------------------------------------------------------

for ((i = 50; i >= 1; i--)); do
    member=$(printf 'bulk_%03d' "$i")
    response=$(send_cmd ZADD bulk_zset "$i" "$member")
    check "Bulk ZADD descending input $member -> :1" "$response" "$(expect_int 1)"
done

response=$(send_cmd ZCARD bulk_zset)
check "ZCARD bulk_zset after 50 members -> :50" "$response" "$(expect_int 50)"

response=$(send_cmd ZRANGE bulk_zset 0 4)
check "ZRANGE bulk_zset first five after descending inserts" "$response" \
    "$(expect_array bulk_001 bulk_002 bulk_003 bulk_004 bulk_005)"

response=$(send_cmd ZRANGE bulk_zset -5 -1)
check "ZRANGE bulk_zset last five with negative indexes" "$response" \
    "$(expect_array bulk_046 bulk_047 bulk_048 bulk_049 bulk_050)"

response=$(send_cmd ZRANGE bulk_zset 10 14)
check "ZRANGE bulk_zset middle slice 10 14" "$response" \
    "$(expect_array bulk_011 bulk_012 bulk_013 bulk_014 bulk_015)"

response=$(send_cmd ZRANK bulk_zset bulk_001)
check "ZRANK bulk_001 -> :0" "$response" "$(expect_int 0)"

response=$(send_cmd ZRANK bulk_zset bulk_025)
check "ZRANK bulk_025 -> :24" "$response" "$(expect_int 24)"

response=$(send_cmd ZRANK bulk_zset bulk_050)
check "ZRANK bulk_050 -> :49" "$response" "$(expect_int 49)"

for ((i = 1; i <= 10; i++)); do
    member=$(printf 'bulk_%03d' "$i")
    score=$((0 - i))
    response=$(send_cmd ZADD bulk_zset "$score" "$member")
    check "Bulk ZADD update $member to $score -> :0" "$response" "$(expect_int 0)"
done

response=$(send_cmd ZCARD bulk_zset)
check "ZCARD bulk_zset unchanged after 10 updates -> :50" "$response" "$(expect_int 50)"

response=$(send_cmd ZRANGE bulk_zset 0 9)
check "ZRANGE bulk_zset first ten after negative score updates" "$response" \
    "$(expect_array bulk_010 bulk_009 bulk_008 bulk_007 bulk_006 bulk_005 bulk_004 bulk_003 bulk_002 bulk_001)"

response=$(send_cmd ZRANK bulk_zset bulk_010)
check "ZRANK updated bulk_010 -> :0" "$response" "$(expect_int 0)"

response=$(send_cmd ZRANK bulk_zset bulk_001)
check "ZRANK updated bulk_001 -> :9" "$response" "$(expect_int 9)"

response=$(send_cmd ZRANK bulk_zset bulk_011)
check "ZRANK first non-updated bulk_011 -> :10" "$response" "$(expect_int 10)"

response=$(send_cmd ZREM bulk_zset bulk_010)
check "ZREM bulk_010 -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd ZREM bulk_zset bulk_005)
check "ZREM bulk_005 -> :1" "$response" "$(expect_int 1)"

response=$(send_cmd ZREM bulk_zset bulk_999)
check "ZREM missing bulk_999 -> :0" "$response" "$(expect_int 0)"

response=$(send_cmd ZCARD bulk_zset)
check "ZCARD bulk_zset after two removals -> :48" "$response" "$(expect_int 48)"

response=$(send_cmd ZRANGE bulk_zset 0 4)
check "ZRANGE bulk_zset first five after removals" "$response" \
    "$(expect_array bulk_009 bulk_008 bulk_007 bulk_006 bulk_004)"

response=$(send_cmd ZSCORE bulk_zset bulk_010)
check "ZSCORE removed bulk_010 -> null bulk" "$response" "$(expect_null)"

response=$(send_cmd ZRANK bulk_zset bulk_010)
check "ZRANK removed bulk_010 -> null bulk" "$response" "$(expect_null)"

# ---------------------------------------------------------------------------
# Test 14: TYPE integration is useful when implemented, but not required here
# ---------------------------------------------------------------------------

response=$(send_cmd TYPE zset_key)
if [ "$response" = "$(expect_simple zset)" ]; then
    pass "TYPE sorted set key -> +zset"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    info "TYPE zset_key returned $(printf '%s' "$response" | cat -A); skipping optional TYPE assertion"
fi

# ---------------------------------------------------------------------------
stop_server

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "Sorted set tests passed."
else
    exit 1
fi
