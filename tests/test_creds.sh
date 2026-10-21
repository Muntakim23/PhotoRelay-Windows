#!/usr/bin/env bash
# =====================================================================
# Regression Test Suite: SEC-01 (OAuth Token Exposure Protection)
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d -t photorelay-creds-XXXXXX)"
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

cp "$SCRIPT_DIR/PhotoRelay-Windows.sh" "$TEMP_DIR/PhotoRelay-Windows.sh"
cat > "$TEMP_DIR/gotohp-cli" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = "creds" ] && [ "$2" = "add" ] && [ "$3" = "-" ]; then
    IFS= read -r token || exit 1
    [ -n "$token" ]
    exit
fi
exit 2
MOCK
chmod 700 "$TEMP_DIR/gotohp-cli"

echo "=========================================================="
echo "  TEST SUITE: SEC-01 OAuth Token Protection"
echo "=========================================================="

PASSED=0
FAILED=0

assert_output_contains() {
    local name="$1"
    local output="$2"
    local pattern="$3"
    if echo "$output" | grep -qE "$pattern"; then
        echo -e "  \033[0;32m[PASS]\033[0m $name"
        PASSED=$((PASSED + 1))
    else
        echo -e "  \033[0;31m[FAIL]\033[0m $name (Expected pattern: '$pattern' in output: '$output')"
        FAILED=$((FAILED + 1))
    fi
}

assert_exit_code() {
    local name="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" -eq "$expected" ]; then
        echo -e "  \033[0;32m[PASS]\033[0m $name (Exit code: $actual)"
        PASSED=$((PASSED + 1))
    else
        echo -e "  \033[0;31m[FAIL]\033[0m $name (Expected exit code: $expected, got: $actual)"
        FAILED=$((FAILED + 1))
    fi
}

# 1. Missing token returns error
OUT1="$(cd "$TEMP_DIR" && PATH="$TEMP_DIR:$PATH" ./PhotoRelay-Windows.sh creds add - </dev/null 2>&1 || true)"
assert_output_contains "Empty stdin to 'creds add -' outputs error" "$OUT1" "No OAuth token provided"

# 2. Positional argument triggers security deprecation warning
OUT2="$(cd "$TEMP_DIR" && PATH="$TEMP_DIR:$PATH" ./PhotoRelay-Windows.sh creds add "dummy_secret_token_12345" 2>&1 || true)"
assert_output_contains "Positional token triggers security warning" "$OUT2" "SECURITY WARNING"
assert_output_contains "Warning advises interactive prompt or stdin" "$OUT2" "creds add -"

# 3. Ensure token value itself is not emitted into error/warning lines
if echo "$OUT2" | grep -q "dummy_secret_token_12345"; then
    echo -e "  \033[0;31m[FAIL]\033[0m Token leaked into security warning output!"
    FAILED=$((FAILED + 1))
else
    echo -e "  \033[0;32m[PASS]\033[0m Raw token string not leaked in warning output"
    PASSED=$((PASSED + 1))
fi

# 4. Standard input pipe mode (echo token | creds add -) accepts input without argument exposure
OUT3="$(printf "test_mock_token\n" | (cd "$TEMP_DIR" && PATH="$TEMP_DIR:$PATH" ./PhotoRelay-Windows.sh creds add -) 2>&1 || true)"
if echo "$OUT3" | grep -q "SECURITY WARNING"; then
    echo -e "  \033[0;31m[FAIL]\033[0m Stdin pipe mode triggered deprecation warning!"
    FAILED=$((FAILED + 1))
else
    echo -e "  \033[0;32m[PASS]\033[0m Stdin pipe mode does not trigger positional argument warning"
    PASSED=$((PASSED + 1))
fi

echo "=========================================================="
echo "  RESULTS: $PASSED Passed, $FAILED Failed"
echo "=========================================================="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
