# =====================================================================
#  PhotoRelay-Windows - Real-Time Watcher
#  Runs on ANY Windows PC, in ANY folder, on PS 5.1 and PS 7+
#  Zero hardcoded paths - Self-contained SQLite engine
# =====================================================================
param(
    [switch]$StatusOnly,
    [switch]$ShowLogs,
    [switch]$EnableStartup,
    [switch]$DisableStartup,
    [switch]$StopWatcher
)
$ErrorActionPreference = "Stop"
$utilityMode = $StatusOnly -or $ShowLogs -or $StopWatcher -or $DisableStartup

# -- Dynamic Base Directory (Wherever this script is located) ----------
$script:BASE = $PSScriptRoot
if (-not $script:BASE) {
    $script:BASE = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $script:BASE) {
    $script:BASE = (Get-Location).Path
}

# -- Executable & Database Discovery -----------------------------------
$script:GOTOHP = $null
$binCandidates = @(
    "gotohp-cli-x64.exe",
    "gotohp-cli.exe",
    "gotohp-x64.exe",
    "gotohp.exe"
)

foreach ($cand in $binCandidates) {
    $testPath = Join-Path $script:BASE $cand
    if ([System.IO.File]::Exists($testPath)) {
        $script:GOTOHP = $testPath
        break
    }
}

if (-not $script:GOTOHP) {
    foreach ($cand in $binCandidates) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($cand)
        $pathCmd = Get-Command $baseName -ErrorAction SilentlyContinue
        if ($pathCmd) {
            $script:GOTOHP = $pathCmd.Source
            break
        }
    }
}

$script:DB = Join-Path $script:BASE "gphotos.db"

# -- Portable Config Discovery (Checks local folder first, then %APPDATA%)
$script:CONFIG_ARGS = @()
$portableConfig = Join-Path $script:BASE "gotohp.config"
if ([System.IO.File]::Exists($portableConfig)) {
    $script:CONFIG_ARGS = @("--config", $portableConfig)
}

# -- Watch folders loaded from FolderManager.bat config ------------------
# watch-folders.txt is the single source of truth for monitored folders.
# Removing a folder here does not delete local files or Google Photos uploads.
$script:WATCH_DIRS = New-Object 'System.Collections.Generic.List[string]'
$watchConfig = Join-Path $script:BASE "watch-folders.txt"

if (-not (Test-Path -LiteralPath $watchConfig -PathType Leaf)) {
    if (-not $utilityMode) {
        throw "Watch folder config not found: $watchConfig. Run OneTime-Setup.bat or add a folder with FolderManager.bat."
    }
}

$folderCandidates = @()
if (Test-Path -LiteralPath $watchConfig -PathType Leaf) {
    $folderCandidates = @(
        Get-Content -LiteralPath $watchConfig |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith("#") }
    )
}

$seenWatchDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

foreach ($cand in $folderCandidates) {
    if (Test-Path -LiteralPath $cand -PathType Container) {
        $resolved = (Resolve-Path -LiteralPath $cand).Path
        if ($seenWatchDirs.Add($resolved)) {
            $script:WATCH_DIRS.Add($resolved)
        }
    }
    else {
        Write-Warning "Skipping missing watch folder: $cand"
    }
}

if ($script:WATCH_DIRS.Count -eq 0 -and -not $utilityMode) {
    throw "No valid watch folders found in $watchConfig. Add at least one existing folder using FolderManager.bat."
}

# -- Supported extensions ----------------------------------------------
$script:EXT = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$extList = @(".jpg", ".jpeg", ".png", ".heic", ".webp", ".gif",
             ".mp4", ".mov", ".mkv", ".avi", ".dng")
foreach ($e in $extList) { $script:EXT.Add($e) | Out-Null }

$script:MIN_BYTES = 10240   # 10 KB minimum file size
$script:MAX_RETRY = 3       # Max retry attempts per file
$script:LOG_RETENTION_DAYS = 30

# In-memory cache for O(1) lookups
$script:history    = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:fileLookup = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:retryMap   = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:inFlight   = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

# Mutex for thread-safe DB access (keyed to normalized database path)
$cleanPath = $script:DB.ToLower().Replace("\", "_").Replace(":", "").Replace(" ", "_")
$mutexName = "GotohpDBMutex_" + $cleanPath
try {
    $script:dbMutex = New-Object System.Threading.Mutex($false, $mutexName)
} catch {
    $script:dbMutex = New-Object System.Threading.Mutex($false, ("Local\" + $cleanPath))
}

# Safe argument formatting helper for Windows CommandLineToArgvW rules
function Format-WindowsArgument([string]$arg) {
    if ([string]::IsNullOrEmpty($arg)) { return '""' }
    if ($arg -notmatch '[\s"\\<>&|^]') { return $arg }
    $escaped = $arg -replace '(\\+)"', '$1$1\"' -replace '(\\+)$', '$1$1' -replace '"', '\"'
    return "`"$escaped`""
}

# Safe fast SHA-256 computation helper
function Get-FileHashSafe([string]$path) {
    try {
        if (-not [System.IO.File]::Exists($path)) { return "" }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = $sha.ComputeHash($stream)
            return [System.BitConverter]::ToString($bytes).Replace("-", "").ToLower()
        } finally {
            $stream.Dispose()
            $sha.Dispose()
        }
    } catch {
        return ""
    }
}

# Safe console writer (never throws IOException in headless/silent background mode)
function Safe-ConsoleWrite([string]$text) {
    try {
        if ([Environment]::UserInteractive) {
            [Console]::Write($text)
        }
    } catch {}
}

# ---------------------------------------------------------------------
# PORTABLE PSSQLITE ENGINE LOADER (Zero configuration required)
# ---------------------------------------------------------------------
if (-not (Get-Module -Name PSSQLite)) {
    $modulePaths = @(
        # 1. Bundled inside script's own directory (Fully portable on USB/any PC)
        (Join-Path $script:BASE "Modules\PSSQLite\PSSQLite.psd1"),
        (Join-Path $script:BASE "Modules\PSSQLite\1.1.0\PSSQLite.psd1"),
        # 2. Installed in user profile
        (Join-Path $env:USERPROFILE "Documents\PowerShell\Modules\PSSQLite\1.1.0\PSSQLite.psd1"),
        (Join-Path $env:USERPROFILE "Documents\PowerShell\Modules\PSSQLite\PSSQLite.psd1"),
        (Join-Path $env:USERPROFILE "Documents\WindowsPowerShell\Modules\PSSQLite\1.1.0\PSSQLite.psd1"),
        (Join-Path $env:USERPROFILE "Documents\WindowsPowerShell\Modules\PSSQLite\PSSQLite.psd1")
    )

    $loaded = $false
    foreach ($mp in $modulePaths) {
        if ([System.IO.File]::Exists($mp)) {
            Import-Module -Name $mp -ErrorAction SilentlyContinue
            $loaded = $true
            break
        }
    }

    if (-not $loaded) {
        # Check standard module discovery
        Import-Module -Name PSSQLite -ErrorAction SilentlyContinue
    }
}

# Auto-install fallback if running on a fresh PC without bundled modules
if (-not (Get-Command -Name Invoke-SqliteQuery -ErrorAction SilentlyContinue)) {
    Write-Host "[Setup] SQLite module not detected. Installing automatically..." -ForegroundColor Yellow
    try {
        Install-Module -Name PSSQLite -Force -Scope CurrentUser -ErrorAction Stop
        Import-Module PSSQLite -ErrorAction Stop
        Write-Host "[Setup] SQLite module installed successfully." -ForegroundColor Green
    } catch {
        Write-Host "ERROR: Could not load or install PSSQLite. Please check internet connection." -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------------
# DB INIT
# ---------------------------------------------------------------------
function Initialize-DB {
    $ddl = @"
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
"@
    Invoke-SqliteQuery -DataSource $script:DB -Query $ddl | Out-Null

    # Schema migration for dual-boot cross-platform tracking
    try {
        Invoke-SqliteQuery -DataSource $script:DB -Query "ALTER TABLE uploads ADD COLUMN file_name TEXT;" -ErrorAction SilentlyContinue | Out-Null
    } catch {}
    try {
        Invoke-SqliteQuery -DataSource $script:DB -Query "ALTER TABLE uploads ADD COLUMN file_size INTEGER;" -ErrorAction SilentlyContinue | Out-Null
    } catch {}
    try {
        Invoke-SqliteQuery -DataSource $script:DB -Query "CREATE INDEX IF NOT EXISTS idx_uploads_file ON uploads(file_name, file_size);" -ErrorAction SilentlyContinue | Out-Null
    } catch {}
    try {
        Invoke-SqliteQuery -DataSource $script:DB -Query "ALTER TABLE uploads ADD COLUMN content_hash TEXT;" -ErrorAction SilentlyContinue | Out-Null
    } catch {}
    try {
        Invoke-SqliteQuery -DataSource $script:DB -Query "CREATE INDEX IF NOT EXISTS idx_uploads_hash ON uploads(content_hash);" -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

# ---------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------
function Write-Log([string]$msg, [string]$level = "INFO") {
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$level] $msg"
    $hasMutex = $false
    try {
        $hasMutex = $script:dbMutex.WaitOne(3000)
        if ($hasMutex) {
            Invoke-SqliteQuery -DataSource $script:DB `
                -Query "INSERT INTO logs(level, message) VALUES(@lv, @m)" `
                -SqlParameters @{ lv = $level; m = $msg } | Out-Null
        }
    } catch {}
    finally {
        if ($hasMutex) {
            try { $script:dbMutex.ReleaseMutex() } catch {}
        }
    }

    switch ($level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor DarkYellow }
        "OK"    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line -ForegroundColor Gray }
    }
}

# ---------------------------------------------------------------------
# CACHE & PRUNE
# ---------------------------------------------------------------------
function Load-Cache {
    $rows = Invoke-SqliteQuery -DataSource $script:DB -Query "SELECT path, file_name, file_size FROM uploads"
    foreach ($r in $rows) {
        if ($r.path) {
            $script:history.Add($r.path) | Out-Null
        }
        if ($r.file_name -and $r.file_size) {
            $script:fileLookup.Add("$($r.file_name)|$($r.file_size)") | Out-Null
        }
    }
    Write-Log "Cache loaded: $($script:history.Count) uploaded files."

    $retries = Invoke-SqliteQuery -DataSource $script:DB -Query "SELECT path, attempts FROM retry_queue"
    foreach ($r in $retries) {
        if ($r.path -and -not $script:history.Contains($r.path)) {
            $script:retryMap[$r.path] = [int]$r.attempts
        }
    }
    if ($script:retryMap.Count -gt 0) {
        Write-Log "Retry queue: $($script:retryMap.Count) file(s) pending." "WARN"
    }

    Invoke-SqliteQuery -DataSource $script:DB `
        -Query "DELETE FROM logs WHERE timestamp < datetime('now', '-$($script:LOG_RETENTION_DAYS) days')" | Out-Null
}

function Save-Upload([string]$path, [string]$mediaKey, [string]$fileName = "", [long]$fileSize = 0, [string]$contentHash = "") {
    if (-not $fileName) { $fileName = [System.IO.Path]::GetFileName($path) }
    if ($fileSize -le 0 -and [System.IO.File]::Exists($path)) {
        try { $fileSize = (New-Object System.IO.FileInfo($path)).Length } catch {}
    }
    if (-not $contentHash -and [System.IO.File]::Exists($path)) {
        $contentHash = Get-FileHashSafe $path
    }

    $hasMutex = $false
    $saved = $false
    try {
        $hasMutex = $script:dbMutex.WaitOne(3000)
        if ($hasMutex) {
            Invoke-SqliteQuery -DataSource $script:DB `
                -Query "INSERT OR REPLACE INTO uploads(path, media_key, file_name, file_size, content_hash) VALUES(@p, @k, @fn, @fs, @h)" `
                -SqlParameters @{ p = $path; k = $mediaKey; fn = $fileName; fs = $fileSize; h = $contentHash } -ErrorAction Stop | Out-Null
            Invoke-SqliteQuery -DataSource $script:DB `
                -Query "DELETE FROM retry_queue WHERE path = @p" `
                -SqlParameters @{ p = $path } -ErrorAction SilentlyContinue | Out-Null
            $saved = $true
        } else {
            Write-Log "Database mutex timeout (3000ms) saving upload for $fileName." "ERROR"
        }
    } catch {
        Write-Log "Failed to persist upload record for $fileName to database: $_" "ERROR"
    } finally {
        if ($hasMutex) {
            try { $script:dbMutex.ReleaseMutex() } catch {}
        }
    }

    if ($saved) {
        $script:history.Add($path) | Out-Null
        if ($fileName -and $fileSize -gt 0) {
            $script:fileLookup.Add("$fileName|$fileSize") | Out-Null
        }
        $null = $script:retryMap.Remove($path)
        return $true
    } else {
        # Keep in retry map so it will be retried on next sweep
        Save-Retry $path 0
        return $false
    }
}

function Save-Retry([string]$path, [int]$attempts) {
    $hasMutex = $false
    try {
        $hasMutex = $script:dbMutex.WaitOne(3000)
        if ($hasMutex) {
            Invoke-SqliteQuery -DataSource $script:DB `
                -Query "INSERT OR REPLACE INTO retry_queue(path, attempts, last_attempt) VALUES(@p, @a, datetime('now','localtime'))" `
                -SqlParameters @{ p = $path; a = $attempts } -ErrorAction SilentlyContinue | Out-Null
        }
        $script:retryMap[$path] = $attempts
    } finally {
        if ($hasMutex) {
            try { $script:dbMutex.ReleaseMutex() } catch {}
        }
    }
}

function Remove-Retry([string]$path) {
    $hasMutex = $false
    try {
        $hasMutex = $script:dbMutex.WaitOne(3000)
        if ($hasMutex) {
            Invoke-SqliteQuery -DataSource $script:DB `
                -Query "DELETE FROM retry_queue WHERE path = @p" `
                -SqlParameters @{ p = $path } -ErrorAction SilentlyContinue | Out-Null
        }
        $null = $script:retryMap.Remove($path)
    } finally {
        if ($hasMutex) {
            try { $script:dbMutex.ReleaseMutex() } catch {}
        }
    }
}

# ---------------------------------------------------------------------
# FILE READINESS CHECK (Handles large files & active downloads)
# ---------------------------------------------------------------------
function Wait-ForFileReady([string]$path) {
    if (-not [System.IO.File]::Exists($path)) { return "NOT_FOUND" }

    $lastSize = -1

    for ($i = 0; $i -lt 30; $i++) {
        try {
            if (-not [System.IO.File]::Exists($path)) { return "NOT_FOUND" }
            $info = New-Object System.IO.FileInfo($path)

            # Reject empty 0-byte placeholders (wait for data to arrive)
            if ($info.Length -le 0) {
                Start-Sleep -Seconds 1
                continue
            }

            # If file size is actively growing/changing, it's still being downloaded/written
            if ($info.Length -ne $lastSize) {
                $lastSize = $info.Length
                Start-Sleep -Seconds 2
                continue
            }

            # File size is stable and > 0. Test exclusive read access to verify writer has closed handle
            $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'None')
            $fs.Close()
            $fs.Dispose()
            return "READY"
        } catch {
            # File is locked by writing process (browser, rendering engine, or copier)
            Start-Sleep -Seconds 2
        }
    }
    return "LOCKED_OR_GROWING"
}

# ---------------------------------------------------------------------
# DELETE LOCAL COPY 30 SECONDS AFTER A CONFIRMED SUCCESSFUL UPLOAD
# The background job checks the file's size and SHA-256 again before deleting,
# so a file replaced or edited during the delay is left untouched.
# ---------------------------------------------------------------------
function Schedule-DeleteAfterBackup([string]$path, [string]$expectedHash, [long]$expectedLength) {
    if ([string]::IsNullOrWhiteSpace($expectedHash)) {
        Write-Log "Local deletion not scheduled because the file hash could not be verified: $path" "WARN"
        return
    }

    try {
        Start-Job -ArgumentList $path, $expectedHash, $expectedLength -ScriptBlock {
            param([string]$targetPath, [string]$targetHash, [long]$targetLength)
            Start-Sleep -Seconds 30
            try {
                if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) { return }
                $currentFile = Get-Item -LiteralPath $targetPath -ErrorAction Stop
                if ([long]$currentFile.Length -ne $targetLength) { return }
                $currentHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                if ($currentHash -ne $targetHash.ToLowerInvariant()) { return }
                Remove-Item -LiteralPath $targetPath -Force -ErrorAction Stop
            } catch {
                # If the file cannot be verified or deleted, preserve it.
            }
        } | Out-Null
        Write-Log "Local copy scheduled for deletion in 30 seconds after successful backup: $([System.IO.Path]::GetFileName($path))" "INFO"
    } catch {
        Write-Log "Could not schedule local deletion for $path : $_" "ERROR"
    }
}

# ---------------------------------------------------------------------
# CORE UPLOAD FUNCTION WITH DYNAMIC IN-PLACE PROGRESS BAR
# ---------------------------------------------------------------------
function Set-TrayStatus([ValidateSet("uploading", "idle", "error")][string]$status) {
    try {
        [System.IO.File]::WriteAllText(
            (Join-Path $script:BASE "tray-status.txt"),
            $status,
            [System.Text.Encoding]::ASCII
        )
    } catch {}
}

if (-not $utilityMode) { Set-TrayStatus "idle" }
function Invoke-Upload([string]$path, [int]$current = 1, [int]$total = 1) {
    if ($path.Contains("\Modules\")) { return }
    $ext = [System.IO.Path]::GetExtension($path).ToLower()
    if (-not $script:EXT.Contains($ext)) { return }
    if ($script:history.Contains($path)) { return }

    $name = [System.IO.Path]::GetFileName($path)
    $fileInfo = New-Object System.IO.FileInfo($path)
    if (-not $fileInfo.Exists) { return }

    # Dual-boot cross-platform deduplication check (avoids duplicate uploads across OSes)
    $lookupKey = "$name|$($fileInfo.Length)"
    if ($script:fileLookup.Contains($lookupKey)) {
        # File with identical name and size exists in database. Check hash to avoid false collisions.
        $candidateHash = Get-FileHashSafe $path
        $existing = Invoke-SqliteQuery -DataSource $script:DB `
            -Query "SELECT content_hash FROM uploads WHERE file_name = @fn AND file_size = @fs AND file_size > 0 LIMIT 1" `
            -SqlParameters @{ fn = $name; fs = $fileInfo.Length } -ErrorAction SilentlyContinue
        
        $isDuplicate = $false
        if ($existing -and $existing.content_hash) {
            if ($existing.content_hash -eq $candidateHash) {
                $isDuplicate = $true
            }
        } elseif ($existing) {
            # Legacy entry without hash: backfill hash and treat as duplicate
            $isDuplicate = $true
            if ($candidateHash) {
                Invoke-SqliteQuery -DataSource $script:DB `
                    -Query "UPDATE uploads SET content_hash = @h WHERE file_name = @fn AND file_size = @fs AND content_hash IS NULL" `
                    -SqlParameters @{ h = $candidateHash; fn = $name; fs = $fileInfo.Length } -ErrorAction SilentlyContinue | Out-Null
            }
        }

        if ($isDuplicate) {
            Save-Upload $path "DUAL_BOOT_SYNC" $name $fileInfo.Length $candidateHash | Out-Null
            return
        }
    }

    if (-not $script:inFlight.Add($path)) { return }

    $uploadFailed = $false
    Set-TrayStatus "uploading"

    try {
        $fileSizeMB = [Math]::Round($fileInfo.Length / 1MB, 2)
        if ($fileSizeMB -lt 1) {
            $sizeLabel = "$([Math]::Round($fileInfo.Length / 1KB, 1)) KB"
        } else {
            $sizeLabel = "$fileSizeMB MB"
        }

        Write-Host ""
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Detected  : $name ($sizeLabel)" -ForegroundColor Cyan
        Write-Host "             Path      : $path"                               -ForegroundColor DarkGray

        $status = Wait-ForFileReady $path
        if ($status -ne "READY") {
            if ($status -eq "NOT_FOUND") {
                Remove-Retry $path
                return
            }

            # File is actively downloading or locked by writer - keep in queue WITHOUT penalty
            $prev = 0
            if ($script:retryMap.ContainsKey($path)) { $prev = $script:retryMap[$path] }
            Write-Log "File still downloading or locked ($name) - remaining in queue for completion." "WARN"
            Save-Retry $path $prev
            return
        }

        # Start gotohp-cli and render live active progress bar with elapsed time
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:GOTOHP
        $uploadArgs = @()
        if ($script:CONFIG_ARGS.Count -gt 0) {
            $uploadArgs += $script:CONFIG_ARGS
        }
        $uploadArgs += @("upload", $path)

        # Support ArgumentList (.NET Core / PS 7) or robustly escaped argument string (PS 5.1)
        if ($psi.PSObject.Properties['ArgumentList']) {
            foreach ($arg in $uploadArgs) {
                [void]$psi.ArgumentList.Add($arg)
            }
        } else {
            $psi.Arguments = ($uploadArgs | ForEach-Object { Format-WindowsArgument $_ }) -join " "
        }

        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $barWidth = 20
        $step = 0

        # Asynchronously read standard output and standard error to avoid pipe deadlocks (BUG-02)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        # Dynamic timeout: Minimum 600s (10 min), plus 1s per 50KB for large files
        $timeoutSeconds = [Math]::Max(600, [int]($fileInfo.Length / 50KB))
        $timedOut = $false

        while (-not $proc.WaitForExit(150)) {
            $elapsedSec = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
            if ($elapsedSec -ge $timeoutSeconds) {
                $timedOut = $true
                try {
                    $proc.Kill()
                } catch {}
                break
            }

            $step = ($step + 1) % $barWidth
            $barChars = [char[]]("-" * $barWidth)
            for ($k = 0; $k -lt 4; $k++) {
                $barChars[($step + $k) % $barWidth] = [char]"#"
            }
            $activeBar = -join $barChars
            Safe-ConsoleWrite("`r  [$activeBar] Uploading $sizeLabel ($($elapsedSec)s)...   ")
        }

        $stdout = ""
        $stderr = ""
        try {
            $stdout = $stdoutTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()
        } catch {}

        $exitCode = if ($timedOut) { -1 } else { $proc.ExitCode }
        $totalTime = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        $doneBar = "#" * $barWidth

        if ($exitCode -eq 0) {
            $mediaKey = ""
            if ($stdout -match '"mediaKey":\s*"([^"]+)"') {
                $mediaKey = $matches[1]
            }
            $contentHash = Get-FileHashSafe $path
            Safe-ConsoleWrite("`r  [$doneBar] 100% [OK] Uploaded in $($totalTime)s: $name ($sizeLabel)        `n")
            Write-Log "SUCCESS | $name ($sizeLabel in $($totalTime)s)" "OK"
            Save-Upload $path $mediaKey $name $fileInfo.Length $contentHash | Out-Null
            Schedule-DeleteAfterBackup $path $contentHash $fileInfo.Length
        } else {
            $uploadFailed = $true
            if ($timedOut) {
                Safe-ConsoleWrite("`r  [--------------------] TIMED OUT after $($totalTime)s: $name                  `n")
                Write-Log "TIMEOUT | Upload exceeded ${timeoutSeconds}s threshold: $name" "ERROR"
            } else {
                Safe-ConsoleWrite("`r  [--------------------] FAILED in $($totalTime)s: $name                      `n")
                if ($stderr -and -not $stdout) {
                    Write-Log "CLI stderr for ${name}: $stderr" "WARN"
                }
            }

            $attempts = 1
            if ($script:retryMap.ContainsKey($path)) {
                $attempts = $script:retryMap[$path] + 1
            }

            if ($attempts -ge $script:MAX_RETRY) {
                Write-Log "GAVE UP after $attempts upload attempts: $name" "ERROR"
                Remove-Retry $path
            } else {
                Write-Log "FAILED upload (attempt $attempts/$($script:MAX_RETRY)) - queued for retry: $name" "WARN"
                Save-Retry $path $attempts
            }
        }
    } catch {
        $uploadFailed = $true
        Write-Log "EXCEPTION for $([System.IO.Path]::GetFileName($path)): $_" "ERROR"
    } finally {
        $null = $script:inFlight.Remove($path)
        if ($script:inFlight.Count -gt 0) {
            Set-TrayStatus "uploading"
        } elseif ($uploadFailed) {
            Set-TrayStatus "error"
        } else {
            Set-TrayStatus "idle"
        }
    }
}

# ---------------------------------------------------------------------
# STARTUP BANNER
# ---------------------------------------------------------------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  *  PhotoRelay-Windows - gotohp (Portable Edition)"   -ForegroundColor Green
Write-Host "  Location: $script:BASE"                                   -ForegroundColor Yellow
Write-Host "  Database: $script:DB"                                     -ForegroundColor Gray
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Watched Folders:" -ForegroundColor DarkCyan
foreach ($dir in $script:WATCH_DIRS) {
    Write-Host "    -> $dir" -ForegroundColor Gray
}
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

if ($StopWatcher) {
    Write-Host "Stopping PhotoRelay-Windows background watcher..." -ForegroundColor Cyan
    $currentPid = $PID
    $stopped = 0
    Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $currentPid -and
        $_.CommandLine -and
        ($_.CommandLine -like "*WatchAndUpload.ps1*" -or $_.CommandLine -like "*StartPhotosWatcher.vbs*")
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] Stopped watcher (PID $($_.ProcessId))" -ForegroundColor Green
        $stopped++
    }
    if ($stopped -gt 0) {
        Write-Host "All background watcher instances have been stopped." -ForegroundColor Green
    } else {
        Write-Host "No active background watcher instances found running." -ForegroundColor Yellow
    }
    return
}

if ($EnableStartup) {
    Write-Host "Setting up PhotoRelay-Windows to run on Windows startup..." -ForegroundColor Cyan
    $startupFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    $shortcutPath = Join-Path $startupFolder "PhotoRelay-Windows.lnk"
    $vbsPath = Join-Path $script:BASE "StartPhotosWatcher.vbs"
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($shortcutPath)
    $s.TargetPath = $vbsPath
    $s.WorkingDirectory = $script:BASE
    $s.Description = "PhotoRelay-Windows Auto-Sync Watcher"
    $s.Save()
    Write-Host "[OK] Startup shortcut created: $shortcutPath" -ForegroundColor Green
    Write-Host "PhotoRelay-Windows will now start automatically in the background on sign-in." -ForegroundColor Yellow
    return
}

if ($DisableStartup) {
    Write-Host "Removing PhotoRelay-Windows from Windows startup..." -ForegroundColor Cyan
    $startupFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    $shortcutPath = Join-Path $startupFolder "PhotoRelay-Windows.lnk"
    if ([System.IO.File]::Exists($shortcutPath)) {
        Remove-Item -LiteralPath $shortcutPath -Force
        Write-Host "[OK] Startup shortcut removed successfully." -ForegroundColor Green
    } else {
        Write-Host "Startup shortcut was not present." -ForegroundColor Yellow
    }
    return
}

if (-not [System.IO.File]::Exists($script:GOTOHP)) {
    Write-Host "ERROR: gotohp binary not found in $script:BASE or system PATH." -ForegroundColor Red
    exit 1
}

# Check for active Google Photos account
$checkArgs = @()
if ($script:CONFIG_ARGS.Count -gt 0) {
    $checkArgs += $script:CONFIG_ARGS
}
$checkArgs += @("creds", "list")

$credsOutput = & $script:GOTOHP $checkArgs 2>&1 | Out-String
if ($credsOutput -match "No credentials found" -or ($credsOutput -notmatch "\*")) {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host "  ACTION REQUIRED: No Google Account Logged In!"            -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host "  Please sign in to Google Photos first:"                  -ForegroundColor White
    Write-Host "    1. Double-click 'gotohp-x64.exe' to log in via GUI, OR" -ForegroundColor Gray
    Write-Host "    2. Run: .\gotohp-cli-x64.exe creds add"                 -ForegroundColor Gray
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host ""
    if (-not ($StatusOnly -or $ShowLogs -or $StopWatcher -or $DisableStartup)) {
        exit 1
    }
}

Initialize-DB
Load-Cache

if ($StatusOnly) {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  *  PhotoRelay-Windows Sync Status"                             -ForegroundColor Green
    Write-Host "  Database: $script:DB"                                     -ForegroundColor Gray
    Write-Host "==========================================================" -ForegroundColor Cyan
    
    $totalCount = $script:history.Count
    $retCount   = $script:retryMap.Count
    Write-Host "  Total Uploaded Files : $totalCount" -ForegroundColor Yellow
    Write-Host "  Pending Retries      : $retCount"   -ForegroundColor $(if ($retCount -gt 0) { "Red" } else { "Green" })
    
    $recent = Invoke-SqliteQuery -DataSource $script:DB `
        -Query "SELECT path, uploaded_at FROM uploads ORDER BY uploaded_at DESC LIMIT 10"
    if ($recent) {
        Write-Host ""
        Write-Host "  Last 10 Uploads:" -ForegroundColor Cyan
        foreach ($r in $recent) {
            $name = [System.IO.Path]::GetFileName($r.path)
            Write-Host "    [$($r.uploaded_at)] $name" -ForegroundColor Gray
        }
    }
    
    if ($retCount -gt 0) {
        Write-Host ""
        Write-Host "  Pending Retries in Queue:" -ForegroundColor DarkYellow
        foreach ($qf in $script:retryMap.Keys) {
            Write-Host "    $qf (attempt $($script:retryMap[$qf]))" -ForegroundColor DarkYellow
        }
    }
    Write-Host "==========================================================" -ForegroundColor Cyan
    return
}

if ($ShowLogs) {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  *  PhotoRelay-Windows Sync - Activity Logs (Last 30)"          -ForegroundColor Green
    Write-Host "  Database: $script:DB"                                     -ForegroundColor Gray
    Write-Host "==========================================================" -ForegroundColor Cyan

    $logRows = Invoke-SqliteQuery -DataSource $script:DB `
        -Query "SELECT timestamp, level, message FROM logs ORDER BY id DESC LIMIT 30"
    if ($logRows) {
        $logArray = @($logRows)
        [Array]::Reverse($logArray)
        foreach ($l in $logArray) {
            $color = switch ($l.level) {
                "ERROR" { "Red" }
                "WARN"  { "DarkYellow" }
                "OK"    { "Green" }
                default { "Gray" }
            }
            Write-Host "[$($l.timestamp)][$($l.level)] $($l.message)" -ForegroundColor $color
        }
    } else {
        Write-Host "  No activity logs found." -ForegroundColor DarkGray
    }
    Write-Host "==========================================================" -ForegroundColor Cyan
    return
}

# Only one uploader may monitor folders in this Windows logon session.
$script:watcherMutex = New-Object System.Threading.Mutex($false, "Local\PhotoRelayWatcher")
$script:ownsWatcherMutex = $false
try {
    $script:ownsWatcherMutex = $script:watcherMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $script:ownsWatcherMutex = $true
}
if (-not $script:ownsWatcherMutex) {
    Write-Host "PhotoRelay-Windows watcher is already running; this instance will exit." -ForegroundColor Yellow
    $script:watcherMutex.Dispose()
    return
}

# ---------------------------------------------------------------------
# PHASE 1 - Startup scan for unrecorded files
# ---------------------------------------------------------------------
try {
Write-Host "[Phase 1] Scanning for unrecorded files..." -ForegroundColor Cyan

$unrecorded = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'

foreach ($dir in $script:WATCH_DIRS) {
    try {
        Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $script:EXT.Contains($_.Extension.ToLower()) -and
                -not $_.FullName.Contains("\Modules\") -and
                -not $script:history.Contains($_.FullName) -and
                -not $script:fileLookup.Contains("$($_.Name)|$($_.Length)")
            } | ForEach-Object { $unrecorded.Add($_) }
    } catch {
        Write-Log "Scan error in $dir - $_" "WARN"
    }
}

# Include pending retry queue files
foreach ($qf in @($script:retryMap.Keys)) {
    $fi = New-Object System.IO.FileInfo($qf)
    if ($fi.Exists -and -not $script:history.Contains($qf)) {
        $unrecorded.Add($fi)
    }
}

if ($unrecorded.Count -eq 0) {
    Write-Host "[Phase 1] [OK] Everything backed up - zero new files." -ForegroundColor Green
} else {
    $total = $unrecorded.Count
    Write-Host "[Phase 1] Found $total file(s) to upload." -ForegroundColor Yellow
    $i = 0
    foreach ($f in $unrecorded) {
        $i++
        $pct = [Math]::Round(($i / $total) * 100)
        Write-Progress -Activity "Startup sync" -Status "[$i/$total] $($f.Name)" -PercentComplete $pct
        Invoke-Upload $f.FullName $i $total
    }
    Write-Progress -Activity "Startup sync" -Completed
    Write-Host "[Phase 1] [OK] Startup sync complete ($total file(s))." -ForegroundColor Green
}

# ---------------------------------------------------------------------
# PHASE 2 - Real-time watchers
# ---------------------------------------------------------------------
Write-Host ""
Write-Host "[Phase 2] Real-time watcher active." -ForegroundColor Yellow
Write-Host "  Waiting for new downloads... Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

$action = { Invoke-Upload $Event.SourceEventArgs.FullPath 1 1 }

$script:watchers = New-Object 'System.Collections.Generic.List[System.IO.FileSystemWatcher]'

foreach ($dir in $script:WATCH_DIRS) {
    try {
        $w = New-Object System.IO.FileSystemWatcher
        $w.Path                  = $dir
        $w.IncludeSubdirectories = $true
        $w.InternalBufferSize    = 65536
        $w.NotifyFilter          = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::LastWrite

        Register-ObjectEvent $w 'Error' -Action {
            Write-Log "FSW buffer overflow on $($Event.Sender.Path)" "WARN"
        } | Out-Null
        Register-ObjectEvent $w 'Created' -Action $action | Out-Null
        Register-ObjectEvent $w 'Renamed' -Action $action | Out-Null

        $w.EnableRaisingEvents = $true
        $script:watchers.Add($w)
    } catch {
        Write-Log "Could not watch $dir - $_" "WARN"
    }
}

# ---------------------------------------------------------------------
# MAIN LOOP - safety sweep every 120 s + retry flush every 30 s
# ---------------------------------------------------------------------
    $lastSweep = [DateTime]::MinValue
    $sweepIntervalSeconds = 120 # shortcut: missed watcher events can take up to 2 minutes to be found.
    $lastRetryFlush = [DateTime]::MinValue
    while ($true) {
        Start-Sleep -Seconds 2

        if (([DateTime]::Now - $lastSweep).TotalSeconds -ge $sweepIntervalSeconds) {
            $lastSweep = [DateTime]::Now

            # Safety sweep
            foreach ($dir in $script:WATCH_DIRS) {
                try {
                    Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue |
                        Where-Object {
                            $script:EXT.Contains($_.Extension.ToLower()) -and
                            -not $_.FullName.Contains("\Modules\") -and
                            -not $script:history.Contains($_.FullName) -and
                            -not $script:fileLookup.Contains("$($_.Name)|$($_.Length)") -and
                            -not $script:inFlight.Contains($_.FullName) -and
                            $_.LastWriteTime -gt ([DateTime]::Now.AddMinutes(-10))
                        } | ForEach-Object {
                            Write-Log "Sweep caught missed file: $($_.Name)" "WARN"
                            Invoke-Upload $_.FullName 1 1
                        }
                } catch {
                    Write-Log "Sweep error in $dir - $_" "WARN"
                }
            }

        }

        if (([DateTime]::Now - $lastRetryFlush).TotalSeconds -ge 30) {
            $lastRetryFlush = [DateTime]::Now

            # Retry queue flush
            foreach ($qf in @($script:retryMap.Keys)) {
                if ($script:history.Contains($qf)) {
                    Remove-Retry $qf
                    continue
                }
                if ([System.IO.File]::Exists($qf)) {
                    if (-not $script:inFlight.Contains($qf)) {
                        Invoke-Upload $qf 1 1
                    }
                } else {
                    # File was deleted or moved - purge from retry queue
                    Remove-Retry $qf
                }
            }
        }
    }
} finally {
    foreach ($w in $script:watchers) {
        try {
            $w.EnableRaisingEvents = $false
            $w.Dispose()
        } catch {}
    }
    Get-EventSubscriber -ErrorAction SilentlyContinue |
        Where-Object { $_.SourceIdentifier -notlike "PowerShell*" } |
        Unregister-Event -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "Watcher stopped. Database: $script:DB" -ForegroundColor Red
    Write-Log "Watcher stopped cleanly." "INFO"
    if ($script:ownsWatcherMutex) {
        try { $script:watcherMutex.ReleaseMutex() } catch {}
    }
    $script:watcherMutex.Dispose()
}
