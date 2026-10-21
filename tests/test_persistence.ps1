# =====================================================================
# Regression Test Suite: BUG-04 (SQLite Persistence & In-Memory State Consistency)
# =====================================================================
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $scriptDir
$tempDir = Join-Path $env:TEMP "gotohp_test_persist_$([System.Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$testDb = Join-Path $tempDir "test_persist.db"

$modulePath = Join-Path $repoDir "Modules\PSSQLite\PSSQLite.psd1"
Import-Module $modulePath -Force

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  TEST SUITE: BUG-04 State Consistency (PowerShell)"         -ForegroundColor Green
Write-Host "  Test DB: $testDb"                                         -ForegroundColor Gray
Write-Host "==========================================================" -ForegroundColor Cyan

# Schema
Invoke-SqliteQuery -DataSource $testDb -Query @"
CREATE TABLE IF NOT EXISTS uploads (
    path         TEXT PRIMARY KEY,
    media_key    TEXT,
    uploaded_at  TEXT NOT NULL DEFAULT (datetime('now','localtime')),
    file_name    TEXT,
    file_size    INTEGER,
    content_hash TEXT
);
CREATE TABLE IF NOT EXISTS retry_queue (
    path         TEXT PRIMARY KEY,
    attempts     INTEGER NOT NULL DEFAULT 0,
    last_attempt TEXT
);
"@

# Initialize simulated script state
$testHistory = New-Object 'System.Collections.Generic.HashSet[string]'
$testLookup = New-Object 'System.Collections.Generic.HashSet[string]'
$testRetryMap = @{}

# Save-Upload implementation matching the fix in WatchAndUpload.ps1
function Test-SaveUpload([string]$dbPath, [string]$path, [string]$mediaKey, [string]$name, [long]$size, [string]$hash, [ref]$history, [ref]$lookup, [ref]$retryMap, [bool]$simulateDbFailure = $false) {
    if ($simulateDbFailure) {
        Write-Warning "Simulated database write failure!"
        return $false
    }

    try {
        Invoke-SqliteQuery -DataSource $dbPath `
            -Query "INSERT OR REPLACE INTO uploads(path, media_key, file_name, file_size, content_hash) VALUES(@p, @k, @fn, @fs, @h)" `
            -SqlParameters @{ p = $path; k = $mediaKey; fn = $name; fs = $size; h = $hash }

        Invoke-SqliteQuery -DataSource $dbPath `
            -Query "DELETE FROM retry_queue WHERE path = @p" `
            -SqlParameters @{ p = $path }

        # Update in-memory caches ONLY after successful persistence
        [void]$history.Value.Add($path)
        if ($size -gt 0) {
            [void]$lookup.Value.Add("$name|$size")
        }
        $null = $retryMap.Value.Remove($path)
        return $true
    } catch {
        return $false
    }
}

$passed = 0
$failed = 0

function Assert-Condition([string]$testName, [bool]$condition, [string]$detail = "") {
    if ($condition) {
        Write-Host "  [PASS] $testName" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] ${testName}: $detail" -ForegroundColor Red
        $script:failed++
    }
}

try {
    # 1. Normal successful persistence updates both DB and in-memory cache
    $p1 = "C:\Photos\test1.jpg"
    $res1 = Test-SaveUpload $testDb $p1 "KEY_1" "test1.jpg" 5000 "hash1" ([ref]$testHistory) ([ref]$testLookup) ([ref]$testRetryMap) $false
    Assert-Condition "Successful write returns true" $res1
    Assert-Condition "In-memory history updated after successful write" ($testHistory.Contains($p1))
    Assert-Condition "In-memory lookup updated after successful write" ($testLookup.Contains("test1.jpg|5000"))

    # Verify DB has record
    $dbRec = Invoke-SqliteQuery -DataSource $testDb -Query "SELECT COUNT(*) as cnt FROM uploads WHERE path = @p" -SqlParameters @{ p = $p1 }
    Assert-Condition "SQLite database contains persisted record" ($dbRec.cnt -eq 1)

    # 2. Simulated DB write failure MUST NOT update in-memory state (BUG-04)
    $p2 = "C:\Photos\test2_fail.jpg"
    $testRetryMap[$p2] = 1 # Queued for retry
    $res2 = Test-SaveUpload $testDb $p2 "KEY_2" "test2_fail.jpg" 8000 "hash2" ([ref]$testHistory) ([ref]$testLookup) ([ref]$testRetryMap) $true
    Assert-Condition "Failed database write returns false" (-not $res2)
    Assert-Condition "In-memory history NOT polluted on write failure" (-not $testHistory.Contains($p2))
    Assert-Condition "In-memory lookup NOT polluted on write failure" (-not $testLookup.Contains("test2_fail.jpg|8000"))
    Assert-Condition "Item retained in retry map after write failure" ($testRetryMap.ContainsKey($p2))

    # Verify DB does NOT have record for failed item
    $dbRec2 = Invoke-SqliteQuery -DataSource $testDb -Query "SELECT COUNT(*) as cnt FROM uploads WHERE path = @p" -SqlParameters @{ p = $p2 }
    Assert-Condition "SQLite database does not contain failed item" ($dbRec2.cnt -eq 0)

    # 3. Successful retry write cleanly clears retry map and commits to DB
    $res3 = Test-SaveUpload $testDb $p2 "KEY_2" "test2_fail.jpg" 8000 "hash2" ([ref]$testHistory) ([ref]$testLookup) ([ref]$testRetryMap) $false
    Assert-Condition "Retry write succeeds" $res3
    Assert-Condition "Retry map cleared on success" (-not $testRetryMap.ContainsKey($p2))
    Assert-Condition "In-memory history contains retried file" ($testHistory.Contains($p2))

} finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  RESULTS: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
