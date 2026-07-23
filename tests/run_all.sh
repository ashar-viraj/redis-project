#!/bin/bash
# Run all stage tests and report a final summary

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
FAILED_STAGES=()

run_stage() {
    local script="$1"
    local name="$2"
    bash "$script"
    if [ $? -eq 0 ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_STAGES+=("$name")
    fi
    echo ""
}

run_stage "$TESTS_DIR/test_bind.sh"               "Stage 1: Bind to port"
run_stage "$TESTS_DIR/test_ping.sh"               "Stage 2: Respond to PING"
run_stage "$TESTS_DIR/test_multiple_ping.sh"      "Stage 3: Multiple PINGs"
run_stage "$TESTS_DIR/test_concurrent_clients.sh" "Stage 4: Concurrent clients"
run_stage "$TESTS_DIR/test_echo.sh"               "Stage 5: ECHO command"
run_stage "$TESTS_DIR/test_set_get.sh"            "Stage 6: SET & GET commands"
run_stage "$TESTS_DIR/test_incr.sh"               "Stage 6 Extended: INCR command"
run_stage "$TESTS_DIR/test_expiry.sh"             "Stage 7: Key expiry (PX/EX)"
run_stage "$TESTS_DIR/test_rpush.sh"              "Stage 8: RPUSH command"
run_stage "$TESTS_DIR/test_lrange.sh"             "Stage 9/10: LRANGE command"
run_stage "$TESTS_DIR/test_lpush.sh"              "Stage 11: LPUSH command"
run_stage "$TESTS_DIR/test_lpop.sh"               "Stage 12: LPOP (multi-element)"
run_stage "$TESTS_DIR/test_blpop.sh"              "Stage 13: BLPOP command"
run_stage "$TESTS_DIR/test_type.sh"               "Stage 14: TYPE command"
run_stage "$TESTS_DIR/test_type_advanced.sh"      "Stage 14 Extended: TYPE advanced cases"
run_stage "$TESTS_DIR/test_xadd_stream.sh"        "Stage 15: XADD create stream"
run_stage "$TESTS_DIR/test_xadd_id_validation.sh" "Stage 16: XADD entry ID validation"
run_stage "$TESTS_DIR/test_xadd_partial_id.sh"    "Stage 17: XADD partial auto-generated IDs"
run_stage "$TESTS_DIR/test_xadd_full_auto_id.sh"  "Stage 18: XADD fully auto-generated IDs"
run_stage "$TESTS_DIR/test_xrange.sh"             "Stage 19: XRANGE stream queries"
run_stage "$TESTS_DIR/test_xrange_start_dash.sh"  "Stage 20: XRANGE with '-' start ID"
run_stage "$TESTS_DIR/test_xrange_end_plus.sh"    "Stage 21: XRANGE with '+' end ID"
run_stage "$TESTS_DIR/test_xread.sh"              "Stage 22: XREAD single stream queries"
run_stage "$TESTS_DIR/test_xread_multiple_streams.sh" "Stage 23: XREAD multiple stream queries"
run_stage "$TESTS_DIR/test_xread_blocking.sh"     "Stage 24/25/26: XREAD blocking queries"
run_stage "$TESTS_DIR/test_watch.sh"              "Stage 27: WATCH/UNWATCH"
run_stage "$TESTS_DIR/test_transactions.sh"       "Stage 28: Transactions (MULTI/EXEC)"
run_stage "$TESTS_DIR/test_replication.sh"        "Stage 29: Replication"
run_stage "$TESTS_DIR/test_rdb_persistence.sh"    "Stage 30: RDB Persistence"
run_stage "$TESTS_DIR/test_aof_persistence.sh"    "Stage 31: AOF Persistence"
run_stage "$TESTS_DIR/test_pubsub.sh"             "Stage 32: Pub/Sub"
run_stage "$TESTS_DIR/test_sorted_sets.sh"        "Stage 33: Sorted Sets"
run_stage "$TESTS_DIR/test_geo.sh"                "Stage 34: Geospatial Commands"
run_stage "$TESTS_DIR/test_acl_auth.sh"           "Stage 35: ACL Authentication"

echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
if [ ${#FAILED_STAGES[@]} -gt 0 ]; then
    echo "Failed:"
    for s in "${FAILED_STAGES[@]}"; do
        echo "  - $s"
    done
    exit 1
else
    echo "All tests passed!"
fi
