# =====================================================================
# Regression Test Suite: BUG-05 (Cross-Platform Deduplication & Hash Check)
# =====================================================================
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $scriptDir
$tempDir = Join-Path $env:TEMP "gotohp_test_dedup_$([System.Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$testDb = Join-Path $tempDir "test_gphotos.db"

# Import SQLite module from repo Modules
$modulePath = Join-Path $repoDir "Modules\PSSQLite\PSSQLite.psd1"
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
} else {
    Write-Warning "PSSQLite module not found at $modulePath"
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  TEST SUITE: BUG-05 Deduplication Collision Avoidance"       -ForegroundColor Green
Write-Host "  Test DB: $testDb"                                         -ForegroundColor Gray
Write-Host "==========================================================" -ForegroundColor Cyan

# Initialize DB with schema
Invoke-SqliteQuery -DataSource $testDb -Query @"
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
"@

function Get-FileHashSafe([string]$path) {
    if (-not [System.IO.File]::Exists($path)) { return $null }
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha.ComputeHash($fs)
        $fs.Close()
        $fs.Dispose()
        return [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()
    } catch {
        return $null
    }
}

function Test-IsDuplicate([string]$path, [string]$dbPath) {
    $fileInfo = New-Object System.IO.FileInfo($path)
    $name = $fileInfo.Name
    $size = $fileInfo.Length

    # 1. Exact path check
    $exact = Invoke-SqliteQuery -DataSource $dbPath -Query "SELECT COUNT(*) as cnt FROM uploads WHERE path = @p" -SqlParameters @{ p = $path }
    if ($exact.cnt -gt 0) { return $true }

    # 2. Check candidate hash against DB records with matching name and size
    $candidateHash = Get-FileHashSafe $path
    $existing = Invoke-SqliteQuery -DataSource $dbPath `
        -Query "SELECT content_hash FROM uploads WHERE file_name = @fn AND file_size = @fs AND file_size > 0 LIMIT 1" `
        -SqlParameters @{ fn = $name; fs = $size }

    if ($existing -and $existing.content_hash) {
        if ($existing.content_hash -eq $candidateHash) {
            return $true
        } else {
            # Different content hash -> NOT duplicate! (BUG-05 fix)
            return $false
        }
    } elseif ($existing) {
        # Legacy entry without hash: treat as duplicate and backfill
        return $true
    }

    return $false
}

$passed = 0
$failed = 0

function Assert-Result([string]$testName, [bool]$actual, [bool]$expected) {
    if ($actual -eq $expected) {
        Write-Host "  [PASS] $testName" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $testName (Expected: $expected, Got: $actual)" -ForegroundColor Red
        $script:failed++
    }
}

try {
    # Create File A (1024 bytes of 'A')
    $dirA = Join-Path $tempDir "FolderA"
    New-Item -ItemType Directory -Path $dirA -Force | Out-Null
    $fileA = Join-Path $dirA "IMG_0001.JPG"
    $bytesA = [System.Text.Encoding]::ASCII.GetBytes("A" * 1024)
    [System.IO.File]::WriteAllBytes($fileA, $bytesA)
    $hashA = Get-FileHashSafe $fileA

    # Save File A to Database
    Invoke-SqliteQuery -DataSource $testDb `
        -Query "INSERT INTO uploads(path, media_key, file_name, file_size, content_hash) VALUES (@p, 'KEY_A', @fn, @fs, @h)" `
        -SqlParameters @{ p = $fileA; fn = "IMG_0001.JPG"; fs = 1024; h = $hashA }

    # 1. Test exact path match
    Assert-Result "Same file path is recognized as duplicate" (Test-IsDuplicate $fileA $testDb) $true

    # 2. Test File B in another directory with IDENTICAL content (true duplicate)
    $dirB = Join-Path $tempDir "FolderB"
    New-Item -ItemType Directory -Path $dirB -Force | Out-Null
    $fileB = Join-Path $dirB "IMG_0001.JPG"
    [System.IO.File]::WriteAllBytes($fileB, $bytesA) # Same content
    Assert-Result "Same name, size, and content in different path is recognized as duplicate" (Test-IsDuplicate $fileB $testDb) $true

    # 3. Test File C in another directory with SAME NAME, SAME SIZE, but DIFFERENT CONTENT (BUG-05)
    $dirC = Join-Path $tempDir "FolderC"
    New-Item -ItemType Directory -Path $dirC -Force | Out-Null
    $fileC = Join-Path $dirC "IMG_0001.JPG"
    $bytesC = [System.Text.Encoding]::ASCII.GetBytes("C" * 1024) # Different content, same length
    [System.IO.File]::WriteAllBytes($fileC, $bytesC)
    Assert-Result "Same name and size but different content is NOT treated as duplicate (BUG-05)" (Test-IsDuplicate $fileC $testDb) $false

    # 4. Test legacy database entry with NULL content_hash
    $fileLegacy = Join-Path $tempDir "legacy.png"
    [System.IO.File]::WriteAllBytes($fileLegacy, (New-Object byte[] 2048))
    Invoke-SqliteQuery -DataSource $testDb `
        -Query "INSERT INTO uploads(path, media_key, file_name, file_size, content_hash) VALUES (@p, 'KEY_LEGACY', 'legacy.png', 2048, NULL)" `
        -SqlParameters @{ p = "D:\OldWindows\legacy.png" }
    
    # Query with new local path: should match legacy record gracefully
    Assert-Result "Legacy entry without content_hash matches gracefully" (Test-IsDuplicate $fileLegacy $testDb) $true

} finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  RESULTS: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
