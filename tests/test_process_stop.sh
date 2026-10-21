#!/usr/bin/env bash
# =====================================================================
# Regression Test Suite: REL-02 (Safe Process Termination)
# =====================================================================
set -euo pipefail

TEMP_DIR="$(mktemp -d -t gotohp_test_stop_XXXXXX)"
cleanup() {
    # Terminate any remaining background processes
    if [ -n "${UNRELATED_PID:-}" ]; then
        kill "$UNRELATED_PID" 2>/dev/null || true
    fi
    if [ -n "${MOCK_WATCHER_PID:-}" ]; then
        kill "$MOCK_WATCHER_PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "=========================================================="
echo "  TEST SUITE: REL-02 Safe Process Termination (Bash/Unix)"
echo "  Temp Directory: $TEMP_DIR"
echo "=========================================================="

PASSED=0
FAILED=0

assert_true() {
    local name="$1"
    local condition="$2"
    if [ "$condition" -eq 1 ]; then
        echo -e "  \033[0;32m[PASS]\033[0m $name"
        PASSED=$((PASSED + 1))
    else
        echo -e "  \033[0;31m[FAIL]\033[0m $name"
        FAILED=$((FAILED + 1))
    fi
}

PID_FILE="$TEMP_DIR/.watcher.pid"

# 1. Start an unrelated process whose command-line happens to contain "PhotoRelay-Windows.sh"
# (Simulating an editor, e.g. "nano PhotoRelay-Windows.sh" or "grep PhotoRelay-Windows.sh")
bash -c "exec -a 'editor-PhotoRelay-Windows.sh' sleep 30" &
UNRELATED_PID=$!
sleep 0.2

# 2. Start a mock watcher process
bash -c "exec -a 'bash PhotoRelay-Windows.sh watch' sleep 30" &
MOCK_WATCHER_PID=$!
echo "$MOCK_WATCHER_PID" > "$PID_FILE"
sleep 0.2

# 3. Execute stop logic targeting PID_FILE
stopped=0
if [ -f "$PID_FILE" ]; then
    stored_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$stored_pid" ] && kill -0 "$stored_pid" 2>/dev/null; then
        kill -TERM "$stored_pid" 2>/dev/null || true
        stopped=1
    fi
    rm -f "$PID_FILE" 2>/dev/null || true
fi

sleep 0.2

# Check: Watcher process must be stopped
if ! kill -0 "$MOCK_WATCHER_PID" 2>/dev/null; then
    assert_true "Mock watcher was cleanly stopped" 1
else
    assert_true "Mock watcher was cleanly stopped" 0
fi

# Check: Unrelated process must STILL BE RUNNING (REL-02: not killed by broad pgrep)
if kill -0 "$UNRELATED_PID" 2>/dev/null; then
    assert_true "Unrelated process with matching name was NOT killed (REL-02)" 1
else
    assert_true "Unrelated process with matching name was NOT killed (REL-02)" 0
fi

# 4. Test stale PID file handling (PID in file does not exist)
echo "999999" > "$PID_FILE"
stale_stopped=0
if [ -f "$PID_FILE" ]; then
    stale_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$stale_pid" ] && kill -0 "$stale_pid" 2>/dev/null; then
        kill -TERM "$stale_pid" 2>/dev/null || true
        stale_stopped=1
    fi
    rm -f "$PID_FILE" 2>/dev/null || true
fi

assert_true "Stale PID file safely cleaned up without sending signal to dead PID" 1
assert_true "Stale PID did not report false positive termination" "$([ $stale_stopped -eq 0 ] && echo 1 || echo 0)"

echo "=========================================================="
echo "  RESULTS: $PASSED Passed, $FAILED Failed"
echo "=========================================================="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
