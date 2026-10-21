#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d -t photorelay-binary-XXXXXX)"
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TEMP_DIR/bin"
cp "$ROOT/PhotoRelay-Windows.sh" "$TEMP_DIR/PhotoRelay-Windows.sh"
cp "$ROOT/gotohp-cli_amd64" "$TEMP_DIR/gotohp-cli_amd64"
printf 'not executable on this OS\n' > "$TEMP_DIR/gotohp-cli-x64.exe"
cat > "$TEMP_DIR/bin/uname" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = "-m" ]; then
    printf '%s\n' "$MOCK_ARCH"
else
    printf '%s\n' Linux
fi
MOCK
chmod +x "$TEMP_DIR/bin/uname"

assert_selected() {
    local platform="$1"
    local arch="$2"
    local expected="$3"
    local output
    output="$(cd "$TEMP_DIR" && OS="$platform" MOCK_ARCH="$arch" PATH="$TEMP_DIR/bin:$PATH" ./PhotoRelay-Windows.sh verify 2>&1)"
    if ! grep -Fq "Checking binary: $TEMP_DIR/$expected" <<< "$output"; then
        echo "[FAIL] $platform/$arch selected the wrong binary"
        echo "$output"
        exit 1
    fi
    echo "[PASS] $platform/$arch selects $expected"
}

assert_selected Linux x86_64 gotohp-cli_amd64
printf 'arm fixture\n' > "$TEMP_DIR/gotohp-cli_arm64"
assert_selected Linux aarch64 gotohp-cli_arm64
printf 'mac fixture\n' > "$TEMP_DIR/gotohp-cli-macos"
assert_selected Darwin arm64 gotohp-cli-macos

echo "[PASS] Platform selection test suite"
