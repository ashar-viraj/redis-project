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
run_stage "$TESTS_DIR/test_expiry.sh"             "Stage 7: Key expiry (PX/EX)"
run_stage "$TESTS_DIR/test_rpush.sh"              "Stage 8: RPUSH command"
run_stage "$TESTS_DIR/test_lrange.sh"             "Stage 9/10: LRANGE command"

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
