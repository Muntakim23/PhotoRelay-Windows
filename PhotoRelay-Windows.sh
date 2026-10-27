#!/usr/bin/env bash
# =====================================================================
# PhotoRelay-Windows - Native Linux & macOS Unified Manager
# Auto-Sync & Real-Time Watcher with Pixel Unlimited Backup
# =====================================================================
set -u
# Security: Enforce restrictive umask so all created files/directories are accessible only by owner (SEC-03)
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="$SCRIPT_DIR/gphotos.db"
PID_FILE="$SCRIPT_DIR/.watcher.pid"
SERVICE_NAME="PhotoRelay-Windows.service"
USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
OS="${OS:-$(uname -s)}"

# Terminal Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GRAY='\033[0;90m'
NC='\033[0m'

# ---------------------------------------------------------------------
# CRYPTOGRAPHIC HASH & BINARY INTEGRITY (BUG-05, SEC-02)
# ---------------------------------------------------------------------
compute_content_hash() {
    local fpath="$1"
    if [ ! -f "$fpath" ]; then
        echo ""
        return 1
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$fpath" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$fpath" 2>/dev/null | awk '{print $1}'
    else
        echo ""
        return 1
    fi
}

get_trusted_checksum() {
    local bname="$1"
    # Official trusted SHA-256 checksums from gotohp v0.11.0 release
    case "$bname" in
        gotohp-cli-macos-universal)
            echo "d697e23c648881cf5e7db7b93f815f6d3dcbd9d7718a40d0edffee90456b0557" ;;
        gotohp-cli_amd64)
            echo "945021d5dbc36a96f53121eb4f907ace39d9457cea1b43107ed1986441b29030" ;;
        gotohp-cli-x64.exe)
            echo "c272a285a03aeea02a909f0b74d36f84c4a29c235c8dee47f7de75c83f15d2b1" ;;
        gotohp-x64.exe)
            echo "5c3f757b9e6b2ffd83934b59274136cf4e67c000265e2eaaa4f34dca6a821088" ;;
        *)
            echo "" ;;
    esac
}

verify_binary() {
    local bin_path="$1"
    if [ ! -f "$bin_path" ]; then
        echo -e "${RED}[ERROR] Binary file not found: $bin_path${NC}" >&2
        return 1
    fi
    local bname
    bname="$(basename "$bin_path")"
    # Downloads are verified before an atomic rename from *.dl to the target.
    bname="${bname%.dl}"
    local expected
    expected="$(get_trusted_checksum "$bname")"
    if [ -z "$expected" ]; then
        echo -e "${YELLOW}[WARN] No trusted checksum configured for $bname (skipping hash check).${NC}"
        return 0
    fi
    local actual
    actual="$(compute_content_hash "$bin_path")"
    if [ -z "$actual" ]; then
        echo -e "${YELLOW}[WARN] Neither sha256sum nor shasum available to verify binary integrity.${NC}"
        return 0
    fi
    if [ "$actual" = "$expected" ]; then
        echo -e "${GREEN}[OK] Verified $bname integrity (SHA-256: ${actual:0:16}...)${NC}"
        return 0
    else
        echo -e "${RED}[ERROR] Binary integrity verification failed for $bname!${NC}" >&2
        echo -e "${RED}  Expected: $expected${NC}" >&2
        echo -e "${RED}  Actual:   $actual${NC}" >&2
        return 1
    fi
}

do_verify() {
    echo ""
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${GREEN}  *  PhotoRelay-Windows - Binary Integrity Check${NC}"
    echo -e "${CYAN}==========================================================${NC}"
    local bin
    bin="$(get_gotohp_bin)"
    if [ -z "$bin" ]; then
        echo -e "${RED}[ERROR] No gotohp-cli binary found in $SCRIPT_DIR${NC}" >&2
        return 1
    fi
    echo "Checking binary: $bin"
    verify_binary "$bin"
}


# ---------------------------------------------------------------------
# BINARY & CONFIG DISCOVERY
# ---------------------------------------------------------------------
get_gotohp_bin() {
    local cands=("$SCRIPT_DIR/gotohp-cli")
    if [ "$OS" = "Darwin" ]; then
        cands+=("$SCRIPT_DIR/gotohp-cli-macos-universal" "$SCRIPT_DIR/gotohp-cli-macos")
    else
        case "$(uname -m)" in
            x86_64|amd64) cands+=("$SCRIPT_DIR/gotohp-cli_amd64") ;;
            aarch64|arm64) cands+=("$SCRIPT_DIR/gotohp-cli_arm64") ;;
        esac
    fi

    for cand in "${cands[@]}"; do
        if [ -s "$cand" ]; then
            chmod +x "$cand" 2>/dev/null || true
            echo "$cand"
            return 0
        fi
    done

    if command -v gotohp-cli >/dev/null 2>&1; then
        command -v gotohp-cli
        return 0
    fi
    echo ""
}

get_gotohp_cmd() {
    local bin
    bin="$(get_gotohp_bin)"
    if [ -z "$bin" ]; then
        echo "ERROR: gotohp-cli binary not found in $SCRIPT_DIR or system PATH." >&2
        echo "Please run: ./PhotoRelay-Windows.sh setup" >&2
        exit 1
    fi
    if [ -f "$SCRIPT_DIR/gotohp.config" ]; then
        echo "$bin|--config|$SCRIPT_DIR/gotohp.config"
    else
        echo "$bin"
    fi
}

run_gotohp() {
    local cmd_spec
    cmd_spec="$(get_gotohp_cmd)"
    IFS='|' read -r -a cmd_arr <<< "$cmd_spec"
    "${cmd_arr[@]}" "$@"
    local ret=$?
    # Security: Ensure gotohp.config retains restrictive 600 permissions
    if [ -f "$SCRIPT_DIR/gotohp.config" ]; then
        chmod 600 "$SCRIPT_DIR/gotohp.config" 2>/dev/null || true
    fi
    return $ret
}

# ---------------------------------------------------------------------
# DATABASE INITIALIZATION & LOGGING
# ---------------------------------------------------------------------
init_db() {
    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] sqlite3 is not installed. Please run: ./PhotoRelay-Windows.sh setup${NC}" >&2
        exit 1
    fi

    # Security: Ensure restricted permissions on database, WAL/SHM journals, and credentials (SEC-03)
    touch "$DB" 2>/dev/null || true
    chmod 600 "$DB"* 2>/dev/null || true
    if [ -f "$SCRIPT_DIR/gotohp.config" ]; then
        chmod 600 "$SCRIPT_DIR/gotohp.config" 2>/dev/null || true
    fi

    sqlite3 "$DB" >/dev/null << 'EOF'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;

CREATE TABLE IF NOT EXISTS uploads (
    path        TEXT PRIMARY KEY,
    media_key   TEXT,
    uploaded_at TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);

CREATE TABLE IF NOT EXISTS retry_queue (
    path         TEXT PRIMARY KEY,
    attempts     INTEGER NOT NULL DEFAULT 0,
    last_attempt TEXT
);

CREATE TABLE IF NOT EXISTS logs (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL DEFAULT (datetime('now','localtime')),
    level     TEXT NOT NULL,
    message   TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_logs_ts    ON logs(timestamp);
CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level);
EOF

    # Dual-boot cross-platform tracking and content hash migration (BUG-05)
    sqlite3 "$DB" "ALTER TABLE uploads ADD COLUMN file_name TEXT;" 2>/dev/null || true
    sqlite3 "$DB" "ALTER TABLE uploads ADD COLUMN file_size INTEGER;" 2>/dev/null || true
    sqlite3 "$DB" "ALTER TABLE uploads ADD COLUMN content_hash TEXT;" 2>/dev/null || true
    sqlite3 "$DB" "CREATE INDEX IF NOT EXISTS idx_uploads_file ON uploads(file_name, file_size);" 2>/dev/null || true
    sqlite3 "$DB" "CREATE INDEX IF NOT EXISTS idx_uploads_hash ON uploads(content_hash);" 2>/dev/null || true
}

write_log() {
    local msg="$1"
    local level="${2:-INFO}"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local escaped_msg="${msg//\'/\'\'}"
    local escaped_level="${level//\'/\'\'}"
    sqlite3 "$DB" "INSERT INTO logs(level, message) VALUES ('$escaped_level', '$escaped_msg');" 2>/dev/null || true
    echo "[$ts][$level] $msg"
}

is_uploaded() {
    local fpath="$1"
    local fname="${2:-$(basename "$fpath")}"
    local fsize="${3:-0}"
    local escaped_path="${fpath//\'/\'\'}"
    local escaped_name="${fname//\'/\'\'}"

    # Ensure fsize is numeric to prevent SQL injection
    if ! [[ "$fsize" =~ ^[0-9]+$ ]]; then
        fsize=0
    fi

    # 1. Exact path match
    local exact
    exact=$(sqlite3 "$DB" "SELECT COUNT(*) FROM uploads WHERE path = '$escaped_path';" 2>/dev/null || echo 0)
    if [ -n "$exact" ] && [ "$exact" -gt 0 ]; then
        return 0
    fi

    # 2. Dual-boot cross-platform deduplication check with content hash verification (BUG-05)
    if [ "$fsize" -gt 0 ]; then
        local match_row
        match_row=$(sqlite3 "$DB" "SELECT content_hash FROM uploads WHERE file_name = '$escaped_name' AND file_size = $fsize AND file_size > 0 LIMIT 1;" 2>/dev/null || true)
        if [ -n "$match_row" ]; then
            local current_hash
            current_hash="$(compute_content_hash "$fpath")"
            if [ -n "$current_hash" ]; then
                # Match against database content_hash to avoid false collisions between different files
                local hash_match
                hash_match=$(sqlite3 "$DB" "SELECT COUNT(*) FROM uploads WHERE file_name = '$escaped_name' AND file_size = $fsize AND content_hash = '$current_hash';" 2>/dev/null || echo 0)
                if [ -n "$hash_match" ] && [ "$hash_match" -gt 0 ]; then
                    return 0
                fi
                # Check for legacy entry where content_hash was not set yet
                local legacy_match
                legacy_match=$(sqlite3 "$DB" "SELECT COUNT(*) FROM uploads WHERE file_name = '$escaped_name' AND file_size = $fsize AND (content_hash IS NULL OR content_hash = '');" 2>/dev/null || echo 0)
                if [ -n "$legacy_match" ] && [ "$legacy_match" -gt 0 ]; then
                    # Backfill content_hash into legacy record
                    sqlite3 "$DB" "UPDATE uploads SET content_hash = '$current_hash' WHERE file_name = '$escaped_name' AND file_size = $fsize AND (content_hash IS NULL OR content_hash = '');" 2>/dev/null || true
                    return 0
                fi
                # Name and size matched, but content hash differs -> NOT duplicate
                return 1
            else
                # Fallback if hash tools unavailable
                return 0
            fi
        fi
    fi

    return 1
}

save_upload() {
    local fpath="$1"
    local mkey="$2"
    local fname="${3:-$(basename "$fpath")}"
    local fsize="${4:-0}"
    local escaped_path="${fpath//\'/\'\'}"
    local escaped_mkey="${mkey//\'/\'\'}"
    local escaped_name="${fname//\'/\'\'}"
    local chash
    chash="$(compute_content_hash "$fpath")"
    local escaped_hash="${chash//\'/\'\'}"

    if ! [[ "$fsize" =~ ^[0-9]+$ ]]; then
        fsize=0
    fi

    sqlite3 "$DB" << EOF
INSERT OR REPLACE INTO uploads(path, media_key, file_name, file_size, content_hash) VALUES ('$escaped_path', '$escaped_mkey', '$escaped_name', $fsize, '$escaped_hash');
DELETE FROM retry_queue WHERE path = '$escaped_path';
EOF
}

save_retry() {
    local fpath="$1"
    local attempts="${2:-0}"
    local escaped_path="${fpath//\'/\'\'}"
    if ! [[ "$attempts" =~ ^[0-9]+$ ]]; then
        attempts=0
    fi
    sqlite3 "$DB" "INSERT OR REPLACE INTO retry_queue(path, attempts, last_attempt) VALUES ('$escaped_path', $attempts, datetime('now','localtime'));" 2>/dev/null || true
}

remove_retry() {
    local fpath="$1"
    local escaped_path="${fpath//\'/\'\'}"
    sqlite3 "$DB" "DELETE FROM retry_queue WHERE path = '$escaped_path';" 2>/dev/null || true
}

# ---------------------------------------------------------------------
# ACTION: SETUP & DEPENDENCIES
# ---------------------------------------------------------------------
do_setup() {
    echo ""
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${GREEN}  *  PhotoRelay-Windows - Setup & Dependency Installer${NC}"
    echo -e "${GRAY}  Location : $SCRIPT_DIR${NC}"
    echo -e "${GRAY}  Platform : $OS ($(uname -m))${NC}"
    echo -e "${CYAN}==========================================================${NC}"

    if [ "$OS" = "Darwin" ]; then
        # macOS dependency check
        local missing=()
        command -v fswatch >/dev/null 2>&1 || missing+=("fswatch")
        command -v sqlite3 >/dev/null 2>&1 || missing+=("sqlite3")
        command -v curl >/dev/null 2>&1 || missing+=("curl")

        if [ ${#missing[@]} -gt 0 ]; then
            echo -e "${YELLOW}[Setup] Missing required macOS tools: ${missing[*]}${NC}"
            if command -v brew >/dev/null 2>&1; then
                echo -e "${YELLOW}[Setup] Installing via Homebrew: brew install ${missing[*]}...${NC}"
                brew install "${missing[@]}"
            else
                echo -e "${RED}[ERROR] Homebrew (brew) is not installed.${NC}"
                echo "Please install Homebrew by running:"
                echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
                echo "Then run: brew install ${missing[*]}"
                exit 1
            fi
        else
            echo -e "${GREEN}[OK] Required packages (fswatch, sqlite3, curl) are already installed.${NC}"
        fi

        # Download gotohp-cli Universal for macOS (Apple Silicon + Intel)
        local target_bin="$SCRIPT_DIR/gotohp-cli-macos-universal"
        if [ ! -s "$target_bin" ]; then
            echo -e "${YELLOW}[Setup] Downloading gotohp-cli Universal for macOS...${NC}"
            local tmp_bin="$target_bin.dl"
            rm -f "$tmp_bin"
            if curl -fSL "https://github.com/xob0t/gotohp/releases/download/v0.11.0/gotohp-cli-macos-universal" -o "$tmp_bin"; then
                if verify_binary "$tmp_bin"; then
                    mv "$tmp_bin" "$target_bin"
                else
                    echo -e "${RED}[SECURITY ERROR] Downloaded macOS binary failed integrity verification! Removing.${NC}" >&2
                    rm -f "$tmp_bin"
                    exit 1
                fi
            else
                echo -e "${RED}[ERROR] Failed to download gotohp-cli Universal for macOS.${NC}" >&2
                rm -f "$tmp_bin"
                exit 1
            fi
        else
            verify_binary "$target_bin" || exit 1
        fi

        # Security: strip Apple quarantine flag & set secure permissions
        if [ -s "$target_bin" ]; then
            xattr -d com.apple.quarantine "$target_bin" 2>/dev/null || true
            chmod 700 "$target_bin" 2>/dev/null || true
        fi

    else
        # Linux dependency check
        local missing=()
        command -v inotifywait >/dev/null 2>&1 || missing+=("inotify-tools")
        command -v sqlite3 >/dev/null 2>&1 || missing+=("sqlite3")
        command -v curl >/dev/null 2>&1 || missing+=("curl")

        if [ ${#missing[@]} -gt 0 ]; then
            echo -e "${YELLOW}[Setup] Installing required packages: ${missing[*]}...${NC}"
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update && sudo apt-get install -y "${missing[@]}"
            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y "${missing[@]}"
            elif command -v pacman >/dev/null 2>&1; then
                sudo pacman -Sy --noconfirm "${missing[@]}"
            elif command -v zypper >/dev/null 2>&1; then
                sudo zypper install -y "${missing[@]}"
            else
                echo -e "${RED}[WARN] Could not identify package manager. Please install manually: ${missing[*]}${NC}"
            fi
        else
            echo -e "${GREEN}[OK] Required packages (inotify-tools, sqlite3, curl) are already installed.${NC}"
        fi

        # Verify/download gotohp-cli for Linux with integrity verification (SEC-02)
        local arch
        arch="$(uname -m)"
        if [ "$arch" = "x86_64" ] || [ "$arch" = "amd64" ]; then
            local target_bin="$SCRIPT_DIR/gotohp-cli_amd64"
            local dl_url="https://github.com/xob0t/gotohp/releases/download/v0.11.0/gotohp-cli_amd64"
            if [ ! -s "$target_bin" ]; then
                echo -e "${YELLOW}[Setup] Downloading gotohp-cli for Linux ($arch)...${NC}"
                local tmp_bin="$target_bin.dl"
                rm -f "$tmp_bin"
                if curl -fSL "$dl_url" -o "$tmp_bin"; then
                    if verify_binary "$tmp_bin"; then
                        mv "$tmp_bin" "$target_bin"
                    else
                        echo -e "${RED}[SECURITY ERROR] Downloaded Linux binary failed integrity verification! Removing.${NC}" >&2
                        rm -f "$tmp_bin"
                        exit 1
                    fi
                else
                    echo -e "${RED}[ERROR] Failed to download gotohp-cli binary.${NC}" >&2
                    rm -f "$tmp_bin"
                    exit 1
                fi
            else
                verify_binary "$target_bin" || exit 1
            fi
            chmod 700 "$target_bin" 2>/dev/null || true
        elif ! command -v gotohp-cli >/dev/null 2>&1; then
            echo -e "${RED}[ERROR] gotohp has no Linux $arch release binary. Install a compatible gotohp-cli and place it on PATH.${NC}" >&2
            exit 1
        else
            echo -e "${GREEN}[OK] Using gotohp-cli from PATH for Linux ($arch).${NC}"
        fi
    fi

    # Set execution permissions on scripts and binaries
    chmod 755 "$SCRIPT_DIR"/*.sh 2>/dev/null || true
    chmod 700 "$SCRIPT_DIR"/gotohp-cli_amd64 "$SCRIPT_DIR"/gotohp-cli-macos-universal 2>/dev/null || true

    # Security: Restrict permissions on sensitive configuration files (SEC-03)
    if [ -f "$SCRIPT_DIR/gotohp.config" ]; then
        chmod 600 "$SCRIPT_DIR/gotohp.config" 2>/dev/null || true
    fi
    if [ -f "$DB" ]; then
        chmod 600 "$DB"* 2>/dev/null || true
    fi
    echo -e "${GREEN}[OK] Security permissions hardened (chmod 600 on secrets, 700 on binaries).${NC}"

    # Check credentials
    local creds_out
    creds_out="$(run_gotohp creds list 2>&1 || true)"
    if echo "$creds_out" | grep -q "\*"; then
        echo -e "${GREEN}[OK] Active Google Photos account detected.${NC}"
    else
        echo ""
        echo -e "${YELLOW}==========================================================${NC}"
        echo -e "${YELLOW}  ACTION REQUIRED: Sign In to Google Photos${NC}"
        echo -e "${YELLOW}==========================================================${NC}"
        echo "  Sign in through gotohp's supported account flow."
        echo "  For CLI credential entry, run: ./PhotoRelay-Windows.sh creds add"
        echo "  Its prompt is hidden; never put tokens in commands or shared files."
        echo -e "${YELLOW}==========================================================${NC}"
    fi

    echo ""
    echo -e "${GREEN}[Setup] Complete! You can now run: ./PhotoRelay-Windows.sh${NC}"
}

# ---------------------------------------------------------------------
# ACTION: STATUS
# ---------------------------------------------------------------------
do_status() {
    init_db
    echo ""
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${GREEN}  *  PhotoRelay-Windows Sync Status${NC}"
    echo -e "${GRAY}  Database: $DB${NC}"
    echo -e "${CYAN}==========================================================${NC}"

    local total_count
    total_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM uploads;" 2>/dev/null || echo 0)
    local retry_count
    retry_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM retry_queue;" 2>/dev/null || echo 0)

    echo -e "  Total Uploaded Files : ${YELLOW}$total_count${NC}"
    if [ "$retry_count" -gt 0 ]; then
        echo -e "  Pending Retries      : ${RED}$retry_count${NC}"
    else
        echo -e "  Pending Retries      : ${GREEN}0${NC}"
    fi

    echo ""
    echo -e "${CYAN}  Last 10 Uploads:${NC}"
    local last_uploads
    last_uploads=$(sqlite3 "$DB" "SELECT uploaded_at, path FROM uploads ORDER BY uploaded_at DESC LIMIT 10;" 2>/dev/null || true)
    if [ -n "$last_uploads" ]; then
        while IFS='|' read -r uploaded_at fpath; do
            fname="${fpath##*[/\\]}"
            echo -e "    ${GRAY}[$uploaded_at]${NC} $fname"
        done <<< "$last_uploads"
    else
        echo -e "    ${GRAY}(None yet)${NC}"
    fi

    if [ "$retry_count" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}  Pending Retries in Queue:${NC}"
        local retries
        retries=$(sqlite3 "$DB" "SELECT path, attempts FROM retry_queue;" 2>/dev/null || true)
        while IFS='|' read -r fpath attempts; do
            fname=$(basename "$fpath")
            echo -e "    ${YELLOW}$fname (attempt $attempts)${NC}"
        done <<< "$retries"
    fi

    echo -e "${CYAN}==========================================================${NC}"
    echo ""
}

# ---------------------------------------------------------------------
# ACTION: ACTIVITY LOGS
# ---------------------------------------------------------------------
do_logs() {
    init_db
    echo ""
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${GREEN}  *  PhotoRelay-Windows Sync - Activity Logs (Last 30)${NC}"
    echo -e "${GRAY}  Database: $DB${NC}"
    echo -e "${CYAN}==========================================================${NC}"

    local log_rows
    log_rows=$(sqlite3 "$DB" "SELECT timestamp, level, message FROM (SELECT id, timestamp, level, message FROM logs ORDER BY id DESC LIMIT 30) ORDER BY id ASC;" 2>/dev/null || true)

    if [ -n "$log_rows" ]; then
        while IFS='|' read -r timestamp level message; do
            local color="$GRAY"
            case "$level" in
                "OK")    color="$GREEN" ;;
                "WARN")  color="$YELLOW" ;;
                "ERROR") color="$RED" ;;
            esac
            echo -e "[$timestamp][${color}$level${NC}] $message"
        done <<< "$log_rows"
    else
        echo -e "  ${GRAY}No activity logs found.${NC}"
    fi

    echo -e "${CYAN}==========================================================${NC}"
    echo ""
}

# ---------------------------------------------------------------------
# ACTION: STOP WATCHER
# ---------------------------------------------------------------------
do_stop() {
    echo -e "${CYAN}Stopping PhotoRelay-Windows background watcher...${NC}"
    local stopped=0

    # 1. Stop via dedicated PID file if present (REL-02)
    if [ -f "$PID_FILE" ]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
            local is_watcher=0
            if [ -d "/proc/$pid" ]; then
                if grep -qa "PhotoRelay-Windows" "/proc/$pid/cmdline" 2>/dev/null; then
                    is_watcher=1
                fi
            elif ps -p "$pid" -o command= 2>/dev/null | grep -q "PhotoRelay-Windows"; then
                is_watcher=1
            fi

            if [ "$is_watcher" -eq 1 ] && [ "$pid" != "$$" ]; then
                kill -TERM "$pid" 2>/dev/null || true
                for ((w=0; w<20; w++)); do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        break
                    fi
                    sleep 0.1
                done
                if kill -0 "$pid" 2>/dev/null; then
                    kill -9 "$pid" 2>/dev/null || true
                fi
                echo -e "${GREEN}[OK] Terminated watcher process PID $pid (from PID file)${NC}"
                stopped=1
            fi
        fi
        rm -f "$PID_FILE" 2>/dev/null || true
    fi

    if [ "$OS" = "Darwin" ]; then
        # Terminate macOS launchd agent if active
        launchctl stop com.photorelay.watcher 2>/dev/null || true
        # Stop the previous label during migration from older installs.
        launchctl stop com.googleunlimited.watcher 2>/dev/null || true
    else
        # Terminate systemd user service if active
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
                systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
                echo -e "${GREEN}[OK] Stopped systemd user service '$SERVICE_NAME'${NC}"
                stopped=1
            fi
        fi
    fi

    if [ "$stopped" -eq 1 ]; then
        echo -e "${GREEN}All background watcher instances have been stopped.${NC}"
    else
        echo -e "${YELLOW}No active watcher instances were found running.${NC}"
    fi
}

# ---------------------------------------------------------------------
# ACTION: ENABLE STARTUP (launchd on macOS / systemd on Linux)
# ---------------------------------------------------------------------
do_enable_startup() {
    # Verify valid credentials before enabling startup service (REL-01)
    local creds_check
    creds_check="$(run_gotohp creds list 2>&1 || true)"
    if ! echo "$creds_check" | grep -q "\*"; then
        echo -e "${RED}[ERROR] No active Google account logged in!${NC}" >&2
        echo "Please sign in before enabling startup service:" >&2
        echo "  ./PhotoRelay-Windows.sh creds add" >&2
        return 1
    fi

    if [ "$OS" = "Darwin" ]; then
        echo -e "${CYAN}Enabling PhotoRelay-Windows on startup (macOS launchd)...${NC}"
        local plist_dir="$HOME/Library/LaunchAgents"
        local plist_file="$plist_dir/com.photorelay.watcher.plist"
        local legacy_plist="$plist_dir/com.googleunlimited.watcher.plist"
        mkdir -p "$plist_dir"

        if [ -f "$legacy_plist" ]; then
            launchctl unload -w "$legacy_plist" 2>/dev/null || true
            rm -f "$legacy_plist"
        fi

        # Prevent restart loops on clean exit or missing auth (REL-01)
        cat << EOF > "$plist_file"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.photorelay.watcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/PhotoRelay-Windows.sh</string>
        <string>watch</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SCRIPT_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF
        chmod 644 "$plist_file"
        if command -v launchctl >/dev/null 2>&1; then
            launchctl unload "$plist_file" 2>/dev/null || true
            launchctl load -w "$plist_file"
        fi

        echo ""
        echo -e "${GREEN}==========================================================${NC}"
        echo -e "${GREEN}  *  Auto-Sync has been enabled for macOS startup!${NC}"
        echo -e "${GREEN}==========================================================${NC}"
        echo "LaunchAgent:     $plist_file"
        echo "Check status:    launchctl list | grep com.photorelay"
        echo "View logs:       ./PhotoRelay-Windows.sh logs"
        echo "Disable anytime: ./PhotoRelay-Windows.sh disable"
        echo ""
        return 0
    fi

    echo -e "${CYAN}Enabling PhotoRelay-Windows on startup (Linux systemd)...${NC}"

    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] systemctl not found. Your Linux distribution does not appear to use systemd.${NC}"
        echo "You can manually add '$SCRIPT_DIR/PhotoRelay-Windows.sh watch' to your desktop autostart or cron (@reboot)."
        exit 1
    fi

    mkdir -p "$USER_SYSTEMD_DIR"

    cat << EOF > "$USER_SYSTEMD_DIR/$SERVICE_NAME"
[Unit]
Description=PhotoRelay-Windows Auto-Sync Watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/PhotoRelay-Windows.sh watch
Restart=on-failure
RestartSec=10
KillMode=mixed

[Install]
WantedBy=default.target
EOF

    echo -e "${GREEN}[OK] Service unit created at: $USER_SYSTEMD_DIR/$SERVICE_NAME${NC}"

    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE_NAME"
    systemctl --user restart "$SERVICE_NAME"

    if command -v loginctl >/dev/null 2>&1; then
        local current_user="${USER:-$(id -un 2>/dev/null || whoami 2>/dev/null || echo "")}"
        if [ -n "$current_user" ]; then
            loginctl enable-linger "$current_user" 2>/dev/null || true
        fi
    fi

    echo ""
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "${GREEN}  *  Auto-Sync has been enabled for Linux startup!${NC}"
    echo -e "${GREEN}==========================================================${NC}"
    echo "Status check:    systemctl --user status $SERVICE_NAME"
    echo "View logs:       ./PhotoRelay-Windows.sh logs"
    echo "Disable anytime: ./PhotoRelay-Windows.sh disable"
    echo ""
}

# ---------------------------------------------------------------------
# ACTION: DISABLE STARTUP (launchd on macOS / systemd on Linux)
# ---------------------------------------------------------------------
do_disable_startup() {
    echo -e "${CYAN}Disabling PhotoRelay-Windows startup service...${NC}"

    if [ "$OS" = "Darwin" ]; then
        local plist_file="$HOME/Library/LaunchAgents/com.photorelay.watcher.plist"
        local legacy_plist="$HOME/Library/LaunchAgents/com.googleunlimited.watcher.plist"
        if [ -f "$legacy_plist" ]; then
            launchctl unload -w "$legacy_plist" 2>/dev/null || true
            rm -f "$legacy_plist"
            echo -e "${GREEN}[OK] Removed older PhotoRelay startup entry.${NC}"
        fi
        if [ -f "$plist_file" ]; then
            launchctl unload -w "$plist_file" 2>/dev/null || true
            rm -f "$plist_file"
            echo -e "${GREEN}[OK] Removed LaunchAgent: $plist_file${NC}"
        fi
        echo ""
        echo -e "${GREEN}==========================================================${NC}"
        echo -e "${GREEN}  *  PhotoRelay-Windows startup has been disabled.${NC}"
        echo -e "${GREEN}==========================================================${NC}"
        echo ""
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
        systemctl --user daemon-reload 2>/dev/null || true
    fi

    if [ -f "$USER_SYSTEMD_DIR/$SERVICE_NAME" ]; then
        rm -f "$USER_SYSTEMD_DIR/$SERVICE_NAME"
        echo -e "${GREEN}[OK] Removed service unit: $USER_SYSTEMD_DIR/$SERVICE_NAME${NC}"
    fi

    echo ""
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "${GREEN}  *  PhotoRelay-Windows startup has been disabled.${NC}"
    echo -e "${GREEN}==========================================================${NC}"
    echo ""
}

# ---------------------------------------------------------------------
# ACTION: CORE WATCHER
# ---------------------------------------------------------------------
wait_for_file_ready() {
    local fpath="$1"
    [ ! -f "$fpath" ] && return 2

    local last_size=-1
    local stable_count=0

    # Bounded timeout loop (30 iterations)
    for ((i=0; i<30; i++)); do
        [ ! -f "$fpath" ] && return 2
        local size
        size=$(stat -c%s "$fpath" 2>/dev/null || stat -f%z "$fpath" 2>/dev/null || echo 0)

        # 0-byte placeholders are not ready yet (wait for write to start)
        if [ "$size" -le 0 ]; then
            sleep 1
            continue
        fi

        # Check if size is actively changing (file still being downloaded/written)
        if [ "$size" -ne "$last_size" ]; then
            last_size="$size"
            stable_count=1
            sleep 1
            continue
        else
            stable_count=$((stable_count + 1))
        fi

        # Once size is stable across checks, verify writer lock
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
                sleep 1
                continue
            fi

            # File is non-empty, size is stable, and writer handle is released -> READY (BUG-01)
            return 0
        fi

        sleep 1
    done
    return 1
}

invoke_upload() {
    local fpath="$1"
    [ -d "$fpath" ] && return
    [ ! -f "$fpath" ] && return
    case "$fpath" in
        */Modules/*) return ;;
        *.db|*.db-wal|*.db-shm|*.config|*.tmp|*.crdownload|*.part) return ;;
    esac

    local ext="${fpath##*.}"
    ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
    local valid_ext="^(jpg|jpeg|png|heic|webp|gif|mp4|mov|mkv|avi|dng)$"
    if ! echo "$ext" | grep -qE "$valid_ext"; then
        return
    fi

    local fname
    fname="$(basename "$fpath")"
    local size_bytes
    size_bytes=$(stat -c%s "$fpath" 2>/dev/null || stat -f%z "$fpath" 2>/dev/null || echo 0)
    local size_mb
    size_mb=$(awk -v b="$size_bytes" 'BEGIN { printf "%.2f", b/1048576 }')

    # Dual-boot cross-platform deduplication check
    if is_uploaded "$fpath" "$fname" "$size_bytes"; then
        return
    fi

    echo ""
    echo "[$(date '+%H:%M:%S')] Detected  : $fname (${size_mb} MB)"
    echo "             Path      : $fpath"

    wait_for_file_ready "$fpath"
    local status=$?
    local escaped_path="${fpath//\'/\'\'}"

    if [ $status -eq 2 ]; then
        remove_retry "$fpath"
        return
    elif [ $status -eq 1 ]; then
        local prev
        prev=$(sqlite3 "$DB" "SELECT attempts FROM retry_queue WHERE path = '$escaped_path';" 2>/dev/null || echo 0)
        [ -z "$prev" ] && prev=0
        write_log "File still downloading/locked ($fname) - remaining in queue." "WARN"
        save_retry "$fpath" "$prev"
        return
    fi

    local start_time
    start_time=$(date +%s)
    local output
    output="$(run_gotohp upload "$fpath" 2>&1)"
    local exit_code=$?
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ $exit_code -eq 0 ]; then
        local mkey
        mkey="$(echo "$output" | grep -o '"mediaKey": *"[^"]*"' | head -n1 | cut -d'"' -f4 || echo "")"
        echo "  [####################] 100% [OK] Uploaded in ${duration}s: $fname (${size_mb} MB)"
        write_log "SUCCESS | $fname (${size_mb} MB in ${duration}s)" "OK"
        save_upload "$fpath" "$mkey" "$fname" "$size_bytes"
    else
        echo "  [--------------------] FAILED in ${duration}s: $fname"
        local attempts
        attempts=$(sqlite3 "$DB" "SELECT attempts FROM retry_queue WHERE path = '$escaped_path';" 2>/dev/null || echo 0)
        [ -z "$attempts" ] && attempts=0
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 3 ]; then
            write_log "GAVE UP after $attempts upload attempts: $fname" "ERROR"
            remove_retry "$fpath"
        else
            write_log "FAILED upload (attempt $attempts/3) - queued for retry: $fname" "WARN"
            save_retry "$fpath" "$attempts"
        fi
    fi
}

do_watch() {
    init_db

    # Check credentials
    local creds_check
    creds_check="$(run_gotohp creds list 2>&1 || true)"
    if ! echo "$creds_check" | grep -q "\*"; then
        echo ""
        echo -e "${RED}==========================================================${NC}"
        echo -e "${YELLOW}  ACTION REQUIRED: No Google Account Logged In!${NC}"
        echo -e "${RED}==========================================================${NC}"
        echo "  Please sign in by running:"
        echo "    ./PhotoRelay-Windows.sh creds add"
        echo -e "${RED}==========================================================${NC}"
        exit 1
    fi

    # Check watcher dependency
    if [ "$OS" = "Darwin" ]; then
        if ! command -v fswatch >/dev/null 2>&1; then
            echo -e "${RED}[ERROR] 'fswatch' is required on macOS for real-time file monitoring.${NC}" >&2
            echo -e "Please install it via Homebrew: ${YELLOW}brew install fswatch${NC}" >&2
            echo "Or run: ./PhotoRelay-Windows.sh setup" >&2
            exit 1
        fi
    else
        if ! command -v inotifywait >/dev/null 2>&1; then
            echo -e "${RED}[ERROR] 'inotifywait' is required on Linux for real-time file monitoring.${NC}" >&2
            echo -e "Please install inotify-tools or run: ./PhotoRelay-Windows.sh setup" >&2
            exit 1
        fi
    fi

    # Discover watched folders
    local watch_dirs=()
    for folder in "$HOME/Downloads" "$HOME/Pictures" "$HOME/Desktop" "$HOME/Documents" "$HOME/Music" "$HOME/Movies" "$HOME/Videos"; do
        if [ -d "$folder" ]; then
            watch_dirs+=("$folder")
        fi
    done

    if [ ${#watch_dirs[@]} -eq 0 ]; then
        mkdir -p "$HOME/Pictures"
        watch_dirs=("$HOME/Pictures")
    fi

    echo ""
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${GREEN}  *  PhotoRelay-Windows - Watcher ($OS)${NC}"
    echo -e "${GRAY}  Location: $SCRIPT_DIR${NC}"
    echo -e "${GRAY}  Database: $DB${NC}"
    echo -e "${CYAN}==========================================================${NC}"
    echo "  Watched Folders:"
    for d in "${watch_dirs[@]}"; do
        echo "    -> $d"
    done
    echo -e "${CYAN}==========================================================${NC}"

    # Phase 1: Startup Scan
    echo -e "${CYAN}[Phase 1] Scanning for unrecorded files...${NC}"
    local valid_ext="^(jpg|jpeg|png|heic|webp|gif|mp4|mov|mkv|avi|dng)$"
    local file_count=0
    while IFS= read -r -d '' file; do
        local ext="${file##*.}"
        ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
        if echo "$ext" | grep -qE "$valid_ext"; then
            local fname
            fname="$(basename "$file")"
            local size_bytes
            size_bytes=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
            if ! is_uploaded "$file" "$fname" "$size_bytes"; then
                file_count=$((file_count + 1))
                invoke_upload "$file"
            fi
        fi
    done < <(find "${watch_dirs[@]}" -type f -print0 2>/dev/null)

    # Check retry queue for previous failures
    local retry_list
    retry_list=$(sqlite3 "$DB" "SELECT path FROM retry_queue WHERE attempts < 3;" 2>/dev/null || true)
    if [ -n "$retry_list" ]; then
        while IFS= read -r rfile; do
            if [ -f "$rfile" ]; then
                local rfname
                rfname="$(basename "$rfile")"
                local rsize_bytes
                rsize_bytes=$(stat -c%s "$rfile" 2>/dev/null || stat -f%z "$rfile" 2>/dev/null || echo 0)
                if ! is_uploaded "$rfile" "$rfname" "$rsize_bytes"; then
                    file_count=$((file_count + 1))
                    invoke_upload "$rfile"
                fi
            fi
        done <<< "$retry_list"
    fi

    if [ "$file_count" -eq 0 ]; then
        echo -e "${GREEN}[Phase 1] [OK] Everything backed up - zero new files.${NC}"
    else
        echo -e "${GREEN}[Phase 1] [OK] Startup sync complete ($file_count file(s)).${NC}"
    fi

    # Phase 2: Real-time Watcher
    echo "$$" > "$PID_FILE"
    local watcher_pid=""
    if [ "$OS" = "Darwin" ]; then
        echo ""
        echo -e "${YELLOW}[Phase 2] Real-time watcher active (fswatch).${NC}"
        echo "  Waiting for new media... Press Ctrl+C to stop."

        while IFS= read -r new_path; do
            invoke_upload "$new_path"
        done < <(fswatch -r -e "/\\." "${watch_dirs[@]}" 2>/dev/null) &
        watcher_pid=$!
    else
        echo ""
        echo -e "${YELLOW}[Phase 2] Real-time watcher active (inotifywait).${NC}"
        echo "  Waiting for new media... Press Ctrl+C to stop."

        while IFS= read -r new_path; do
            invoke_upload "$new_path"
        done < <(inotifywait -m -r -e close_write,moved_to,create --format '%w%f' "${watch_dirs[@]}" 2>/dev/null) &
        watcher_pid=$!
    fi

    cleanup() {
        # Untrap immediately to prevent recursive signal/exit loops
        trap - SIGINT SIGTERM EXIT
        echo ""
        echo "Stopping watcher..."
        rm -f "$PID_FILE" 2>/dev/null || true
        if [ -n "${watcher_pid:-}" ]; then
            pkill -P "$watcher_pid" 2>/dev/null || true
            kill "$watcher_pid" 2>/dev/null || true
        fi
        exit 0
    }
    trap cleanup SIGINT SIGTERM EXIT

    wait "$watcher_pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------
# SECURE CREDENTIALS HANDLER (SEC-01)
# ---------------------------------------------------------------------
do_creds() {
    local subcmd="${1:-}"
    shift || true

    if [ "$subcmd" = "add" ]; then
        local token="${1:-}"
        if [ -z "$token" ] || [ "$token" = "-" ]; then
            if [ -t 0 ]; then
                # Interactive terminal: prompt with hidden input (SEC-01)
                local stty_state=""
                stty_state="$(stty -g 2>/dev/null || true)"
                restore_stty() {
                    if [ -n "$stty_state" ]; then
                        stty "$stty_state" 2>/dev/null || true
                    fi
                }
                trap restore_stty INT TERM EXIT
                echo -n "Enter Google OAuth token (hidden): " >&2
                stty -echo 2>/dev/null || true
                read -r token
                stty echo 2>/dev/null || true
                echo "" >&2
                trap - INT TERM EXIT
                restore_stty
            else
                # Pipe or redirected standard input (creds add -)
                read -r token
            fi

            if [ -z "$token" ]; then
                echo -e "${RED}[ERROR] No OAuth token provided.${NC}" >&2
                return 1
            fi
            printf "%s\n" "$token" | run_gotohp creds add -
        else
            # Positional argument provided: print deprecation warning (SEC-01)
            echo -e "${YELLOW}[SECURITY WARNING] Passing OAuth tokens via command-line arguments exposes them in process listings and shell history.${NC}" >&2
            echo -e "${YELLOW}Please use: ./PhotoRelay-Windows.sh creds add (interactive hidden prompt) or pipe: creds add -${NC}" >&2
            printf "%s\n" "$token" | run_gotohp creds add -
        fi
    else
        run_gotohp creds "$subcmd" "$@"
    fi
}

# ---------------------------------------------------------------------
# INTERACTIVE TERMINAL MENU
# ---------------------------------------------------------------------
show_menu() {
    clear 2>/dev/null || true
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${GREEN}  *  PhotoRelay-Windows - Unix Manager ($OS)${NC}"
    echo -e "${CYAN}==========================================================${NC}"
    echo "  [1] Start Live Watcher (Foreground)"
    echo "  [2] Check Backup Status"
    echo "  [3] View Activity Logs"
    echo "  [4] Run Setup & Dependency Installer"
    if [ "$OS" = "Darwin" ]; then
        echo "  [5] Enable Auto-Start on Boot (macOS launchd)"
    else
        echo "  [5] Enable Auto-Start on Boot (Linux systemd)"
    fi
    echo "  [6] Disable Auto-Start on Boot"
    echo "  [7] Stop Background Watcher"
    echo "  [8] Verify Binary Integrity"
    echo "  [0] Exit"
    echo -e "${CYAN}==========================================================${NC}"
    read -rp "Select an option [0-8, Default: 1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) do_watch ;;
        2) do_status ;;
        3) do_logs ;;
        4) do_setup ;;
        5) do_enable_startup ;;
        6) do_disable_startup ;;
        7) do_stop ;;
        8) do_verify ;;
        0) exit 0 ;;
        *) echo "Invalid option"; sleep 1; show_menu ;;
    esac
}

show_help() {
    echo "Usage: ./PhotoRelay-Windows.sh [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  watch             Start live real-time sync watcher (default)"
    echo "  status            Check upload count and pending retries"
    echo "  logs              View last 30 sync activity log entries"
    echo "  setup             Install dependencies (fswatch/inotify-tools, sqlite3)"
    echo "  enable            Enable auto-start on boot (launchd on macOS / systemd on Linux)"
    echo "  disable           Disable auto-start service"
    echo "  stop              Stop running background watcher instances"
    echo "  verify            Verify gotohp-cli binary integrity using trusted SHA-256"
    echo "  creds             Manage credentials securely (creds add / creds list)"
    echo "  menu              Open interactive terminal menu"
    echo "  help              Show this help message"
}

# ---------------------------------------------------------------------
# CLI DISPATCHER
# ---------------------------------------------------------------------
CMD="${1:-}"
case "$CMD" in
    watch|--watch|run|--run)
        do_watch
        ;;
    status|--status|-s)
        do_status
        ;;
    logs|--logs|-l)
        do_logs
        ;;
    setup|--setup)
        do_setup
        ;;
    enable|enable-startup|--enable)
        do_enable_startup
        ;;
    disable|disable-startup|--disable)
        do_disable_startup
        ;;
    stop|--stop)
        do_stop
        ;;
    verify|--verify)
        do_verify
        ;;
    creds)
        shift
        do_creds "$@"
        ;;
    menu|--menu)
        show_menu
        ;;
    help|--help|-h)
        show_help
        ;;
    "")
        if [ -t 0 ]; then
            show_menu
        else
            do_watch
        fi
        ;;
    *)
        echo "Unknown command: $CMD"
        show_help
        exit 1
        ;;
esac
