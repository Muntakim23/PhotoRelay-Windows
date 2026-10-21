#!/usr/bin/env bash
# =====================================================================
# Regression Test Suite: BUG-01 (File Readiness for Small & Growing Files - Unix)
# =====================================================================
set -euo pipefail

TEMP_DIR="$(mktemp -d -t gotohp_test_readiness_XXXXXX)"
cleanup() {
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "=========================================================="
echo "  TEST SUITE: BUG-01 File Readiness (Bash/Unix)"
echo "  Temp Directory: $TEMP_DIR"
echo "=========================================================="

# Replicate wait_for_file_ready logic from PhotoRelay-Windows.sh
test_wait_for_file_ready() {
    local fpath="$1"
    local max_checks="${2:-5}"
    [ ! -f "$fpath" ] && return 2

    local last_size=-1
    local stable_count=0

    for ((i=0; i<max_checks; i++)); do
        [ ! -f "$fpath" ] && return 2
        local size
        size=$(stat -c%s "$fpath" 2>/dev/null || stat -f%z "$fpath" 2>/dev/null || echo 0)

        # 0-byte placeholders are not ready yet
        if [ "$size" -le 0 ]; then
            sleep 0.1
            continue
        fi

        # Check stability across consecutive samples
        if [ "$size" -ne "$last_size" ]; then
            last_size="$size"
            stable_count=1
            sleep 0.1
            continue
        else
            stable_count=$((stable_count + 1))
        fi

        if [ "$stable_count" -ge 2 ]; then
            local locked=0
            if command -v lsof >/dev/null 2>&1; then
                if lsof "$fpath" 2>/dev/null | grep -qE " (W|u) "; then
                    locked=1
                fi
            elif command -v fuser >/dev/null 2>&1; then
                if fuser -s "$fpath" 2>/dev/null; then
                    locked=1
                fi
            fi

            if [ "$locked" -eq 1 ]; then
                sleep 0.1
                continue
            fi

            return 0
        fi

        sleep 0.1
    done
    return 1
}

PASSED=0
FAILED=0

assert_result() {
    local name="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" -eq "$expected" ]; then
        echo -e "  \033[0;32m[PASS]\033[0m $name (Result: $actual)"
        PASSED=$((PASSED + 1))
    else
        echo -e "  \033[0;31m[FAIL]\033[0m $name (Expected: $expected, Got: $actual)"
        FAILED=$((FAILED + 1))
    fi
}

# 1. Valid file below 10 KB (512 bytes) - MUST RETURN 0 (READY)
SMALL_FILE="$TEMP_DIR/valid_small.jpg"
head -c 512 /dev/urandom > "$SMALL_FILE"
test_wait_for_file_ready "$SMALL_FILE" && res1=0 || res1=$?
assert_result "Valid small file < 10 KB (512 bytes) returns READY (0)" "$res1" 0

# 2. Valid file below 10 KB (4096 bytes) - MUST RETURN 0 (READY)
SMALL_FILE2="$TEMP_DIR/valid_4k.png"
head -c 4096 /dev/urandom > "$SMALL_FILE2"
test_wait_for_file_ready "$SMALL_FILE2" && res2=0 || res2=$?
assert_result "Valid small file < 10 KB (4096 bytes) returns READY (0)" "$res2" 0

# 3. Zero-byte placeholder file - MUST TIME OUT (1)
ZERO_FILE="$TEMP_DIR/zero.tmp"
touch "$ZERO_FILE"
test_wait_for_file_ready "$ZERO_FILE" 3 && res3=0 || res3=$?
assert_result "Zero-byte placeholder file returns TIMEOUT (1)" "$res3" 1

# 4. Missing file - MUST RETURN NOT_FOUND (2)
MISSING_FILE="$TEMP_DIR/nonexistent.jpg"
test_wait_for_file_ready "$MISSING_FILE" && res4=0 || res4=$?
assert_result "Missing file returns NOT_FOUND (2)" "$res4" 2

# 5. Growing file during check
GROWING_FILE="$TEMP_DIR/growing.mp4"
echo "start" > "$GROWING_FILE"
( sleep 0.15; echo "more data" >> "$GROWING_FILE"; sleep 0.15; echo "done" >> "$GROWING_FILE" ) &
BG_PID=$!
test_wait_for_file_ready "$GROWING_FILE" 15 && res5=0 || res5=$?
wait "$BG_PID" 2>/dev/null || true
assert_result "Growing file eventually stabilizes and returns READY (0)" "$res5" 0

echo "=========================================================="
echo "  RESULTS: $PASSED Passed, $FAILED Failed"
echo "=========================================================="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
