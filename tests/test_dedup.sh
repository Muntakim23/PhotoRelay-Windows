#!/usr/bin/env bash
# =====================================================================
# Regression Test Suite: BUG-05 (Cross-Platform Deduplication - Unix)
# =====================================================================
set -euo pipefail

TEMP_DIR="$(mktemp -d -t gotohp_test_dedup_XXXXXX)"
cleanup() {
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

TEST_DB="$TEMP_DIR/test_gphotos.db"

echo "=========================================================="
echo "  TEST SUITE: BUG-05 Deduplication (Bash/Unix)"
echo "  Test DB: $TEST_DB"
echo "=========================================================="

sqlite3 "$TEST_DB" << 'EOF'
CREATE TABLE IF NOT EXISTS uploads (
    path         TEXT PRIMARY KEY,
    media_key    TEXT,
    uploaded_at  TEXT NOT NULL DEFAULT (datetime('now','localtime')),
    file_name    TEXT,
    file_size    INTEGER,
    content_hash TEXT
);
CREATE INDEX IF NOT EXISTS idx_uploads_file ON uploads(file_name, file_size);
CREATE INDEX IF NOT EXISTS idx_uploads_hash ON uploads(content_hash);
EOF

compute_hash() {
    local fpath="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$fpath" | awk '{print $1}'
    else
        shasum -a 256 "$fpath" | awk '{print $1}'
    fi
}

test_is_uploaded() {
    local fpath="$1"
    local fname
    fname="$(basename "$fpath")"
    local fsize
    fsize="$(stat -c%s "$fpath" 2>/dev/null || stat -f%z "$fpath" 2>/dev/null || echo 0)"
    local escaped_path="${fpath//\'/\'\'}"
    local escaped_name="${fname//\'/\'\'}"

    # 1. Exact path
    local exact
    exact=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM uploads WHERE path = '$escaped_path';" 2>/dev/null || echo 0)
    if [ "$exact" -gt 0 ]; then
        return 0
    fi

    # 2. Check candidate hash against records with matching name and size
    if [ "$fsize" -gt 0 ]; then
        local match_row
        match_row=$(sqlite3 "$TEST_DB" "SELECT content_hash FROM uploads WHERE file_name = '$escaped_name' AND file_size = $fsize LIMIT 1;" 2>/dev/null || true)
        if [ -n "$match_row" ]; then
            local current_hash
            current_hash="$(compute_hash "$fpath")"
            local hash_match
            hash_match=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM uploads WHERE file_name = '$escaped_name' AND file_size = $fsize AND content_hash = '$current_hash';" 2>/dev/null || echo 0)
            if [ "$hash_match" -gt 0 ]; then
                return 0
            fi
            # Legacy entry without content_hash
            local legacy_match
            legacy_match=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM uploads WHERE file_name = '$escaped_name' AND file_size = $fsize AND (content_hash IS NULL OR content_hash = '');" 2>/dev/null || echo 0)
            if [ "$legacy_match" -gt 0 ]; then
                return 0
            fi
            return 1
        fi
    fi

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

# Create File A (1024 bytes of 'A')
FILE_A="$TEMP_DIR/FolderA/photo.jpg"
mkdir -p "$TEMP_DIR/FolderA"
head -c 1024 < /dev/zero | tr '\0' 'A' > "$FILE_A"
HASH_A="$(compute_hash "$FILE_A")"

# Insert File A into test DB
sqlite3 "$TEST_DB" "INSERT INTO uploads(path, media_key, file_name, file_size, content_hash) VALUES ('$FILE_A', 'KEY_A', 'photo.jpg', 1024, '$HASH_A');"

# 1. Exact path
test_is_uploaded "$FILE_A" && res1=0 || res1=$?
assert_result "Exact path match returns 0 (duplicate)" "$res1" 0

# 2. File B with identical name, size, and content
FILE_B="$TEMP_DIR/FolderB/photo.jpg"
mkdir -p "$TEMP_DIR/FolderB"
head -c 1024 < /dev/zero | tr '\0' 'A' > "$FILE_B"
test_is_uploaded "$FILE_B" && res2=0 || res2=$?
assert_result "Identical content in different folder returns 0 (duplicate)" "$res2" 0

# 3. File C with SAME NAME, SAME SIZE, but DIFFERENT CONTENT (BUG-05)
FILE_C="$TEMP_DIR/FolderC/photo.jpg"
mkdir -p "$TEMP_DIR/FolderC"
head -c 1024 < /dev/zero | tr '\0' 'Z' > "$FILE_C"
test_is_uploaded "$FILE_C" && res3=0 || res3=$?
assert_result "Same name and size but different content returns 1 (NOT duplicate)" "$res3" 1

echo "=========================================================="
echo "  RESULTS: $PASSED Passed, $FAILED Failed"
echo "=========================================================="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
