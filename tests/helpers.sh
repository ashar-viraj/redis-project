#!/bin/bash
# Shared helpers for all test scripts

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$REPO_ROOT/build/redis"
SERVER_PID=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

build_server() {
    info "Building..."
    cmake -B "$REPO_ROOT/build" -S "$REPO_ROOT" \
        -DCMAKE_TOOLCHAIN_FILE="${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" \
        -DCMAKE_BUILD_TYPE=Debug \
        > /dev/null 2>&1
    cmake --build "$REPO_ROOT/build" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        fail "Build failed"
        exit 1
    fi
    info "Build OK"
}

start_server() {
    # Kill any leftover process on 6379
    fuser -k 6379/tcp > /dev/null 2>&1 || true
    sleep 0.2
    "$BINARY" > /tmp/redis_test.log 2>&1 &
    SERVER_PID=$!
    # Stream server logs to terminal with a prefix, in background
    tail -f /tmp/redis_test.log 2>/dev/null | sed 's/^/  \x1b[2m[server]\x1b[0m /' &
    TAIL_PID=$!
    SERVER_PID=$!
    sleep 0.3   # let it bind
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        fail "Server failed to start (see /tmp/redis_test.log)"
        exit 1
    fi
    info "Server started (PID $SERVER_PID)"
}

stop_server() {
    if [ -n "$TAIL_PID" ]; then
        kill "$TAIL_PID" 2>/dev/null
        TAIL_PID=""
    fi
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
    fi
    fuser -k 6379/tcp > /dev/null 2>&1 || true
    SERVER_PID=""
}

# Trap to always clean up
trap stop_server EXIT
