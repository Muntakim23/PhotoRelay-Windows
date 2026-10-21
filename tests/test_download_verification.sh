#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d -t photorelay-download-XXXXXX)"
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/project"
cp "$ROOT/PhotoRelay-Windows.sh" "$TEMP_DIR/project/PhotoRelay-Windows.sh"
cat > "$TEMP_DIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
target=""
url=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        target="$2"
        shift 2
    else
        case "$1" in https://*) url="$1" ;; esac
        shift
    fi
done
printf '%s\n' "$url" > "$MOCK_URL_LOG"
cp "$MOCK_BINARY" "$target"
MOCK
for tool in sqlite3 inotifywait; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TEMP_DIR/bin/$tool"
done
chmod +x "$TEMP_DIR/bin"/*

output="$(cd "$TEMP_DIR/project" && OS=Linux PATH="$TEMP_DIR/bin:$PATH" \
    MOCK_BINARY="$ROOT/gotohp-cli_amd64" MOCK_URL_LOG="$TEMP_DIR/url.txt" \
    ./PhotoRelay-Windows.sh setup 2>&1)"

if ! grep -Fq '[OK] Verified gotohp-cli_amd64 integrity' <<< "$output"; then
    echo "[FAIL] Downloaded temporary binary was not checked against its release checksum"
    echo "$output"
    exit 1
fi
if [ "$(cat "$TEMP_DIR/url.txt")" != "https://github.com/xob0t/gotohp/releases/download/v0.11.0/gotohp-cli_amd64" ]; then
    echo "[FAIL] Setup did not request the pinned gotohp release asset"
    cat "$TEMP_DIR/url.txt"
    exit 1
fi
if [ ! -s "$TEMP_DIR/project/gotohp-cli_amd64" ] || [ -e "$TEMP_DIR/project/gotohp-cli_amd64.dl" ]; then
    echo "[FAIL] Verified binary was not installed atomically"
    exit 1
fi

echo '[PASS] Downloaded gotohp binary is checksum-verified and promoted'
