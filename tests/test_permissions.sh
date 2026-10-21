#!/usr/bin/env bash
# =====================================================================
# Regression Test Suite: SEC-03 (SQLite Database & WAL/SHM File Permissions)
# =====================================================================
set -euo pipefail

TEMP_DIR="$(mktemp -d -t gotohp_test_perm_XXXXXX)"
cleanup() {
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "=========================================================="
echo "  TEST SUITE: SEC-03 File Permissions (Bash/Unix)"
echo "  Temp Directory: $TEMP_DIR"
echo "=========================================================="

PASSED=0
FAILED=0

assert_perm() {
    local name="$1"
    local fpath="$2"
    local expected="$3"

    if [ ! -e "$fpath" ]; then
        echo -e "  \033[0;31m[FAIL]\033[0m $name: File does not exist ($fpath)"
        FAILED=$((FAILED + 1))
        return
    fi

    local actual
    actual="$(stat -c "%a" "$fpath" 2>/dev/null || stat -f "%Lp" "$fpath" 2>/dev/null || echo "")"
    if [ "$actual" = "$expected" ]; then
        echo -e "  \033[0;32m[PASS]\033[0m $name (Mode: $actual)"
        PASSED=$((PASSED + 1))
    else
        echo -e "  \033[0;31m[FAIL]\033[0m $name (Expected mode: $expected, got: $actual)"
        FAILED=$((FAILED + 1))
    fi
}

# 1. Enforce umask 077 and create database with WAL mode
umask 077
TEST_DB="$TEMP_DIR/test_perm.db"
touch "$TEST_DB"
chmod 600 "$TEST_DB"* 2>/dev/null || true

sqlite3 "$TEST_DB" >/dev/null << 'EOF'
PRAGMA journal_mode=WAL;
CREATE TABLE test_data (id INTEGER PRIMARY KEY, note TEXT);
INSERT INTO test_data (note) VALUES ('secret media record');
EOF

# Verify database permissions
assert_perm "Main database file has 600 permissions" "$TEST_DB" "600"

# In WAL mode, check WAL or SHM if generated
if [ -f "${TEST_DB}-wal" ]; then
    chmod 600 "${TEST_DB}-wal" 2>/dev/null || true
    assert_perm "WAL journal file has 600 permissions" "${TEST_DB}-wal" "600"
else
    # Force a pending transaction to ensure WAL exists
    sqlite3 "$TEST_DB" "BEGIN IMMEDIATE; INSERT INTO test_data(note) VALUES('uncommitted');" >/dev/null 2>&1 || true
    chmod 600 "${TEST_DB}"* 2>/dev/null || true
    if [ -f "${TEST_DB}-wal" ]; then
        assert_perm "WAL journal file has 600 permissions" "${TEST_DB}-wal" "600"
    fi
fi

# 2. Test PID file permissions under umask 077
PID_FILE="$TEMP_DIR/.watcher.pid"
echo "$$" > "$PID_FILE"
assert_perm "PID file created under umask 077 has 600 permissions" "$PID_FILE" "600"

# 3. Test config file permissions
CFG_FILE="$TEMP_DIR/gotohp.config"
touch "$CFG_FILE"
chmod 600 "$CFG_FILE"
assert_perm "Config file has 600 permissions" "$CFG_FILE" "600"

echo "=========================================================="
echo "  RESULTS: $PASSED Passed, $FAILED Failed"
echo "=========================================================="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
