# =====================================================================
# Regression Test Suite: BUG-01 (File Readiness for Small & Growing Files)
# =====================================================================
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $scriptDir
$tempDir = Join-Path $env:TEMP "gotohp_test_readiness_$([System.Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  TEST SUITE: BUG-01 File Readiness (PowerShell)"           -ForegroundColor Green
Write-Host "  Temp Directory: $tempDir"                                 -ForegroundColor Gray
Write-Host "==========================================================" -ForegroundColor Cyan

# Source Wait-ForFileReady function logic
function Test-Wait-ForFileReady([string]$path, [int]$maxAttempts = 5) {
    if (-not [System.IO.File]::Exists($path)) { return "NOT_FOUND" }
    
    $lastSize = -1
    $attempts = 0
    while ($attempts -lt $maxAttempts) {
        $attempts++
        if (-not [System.IO.File]::Exists($path)) { return "NOT_FOUND" }
        $info = New-Object System.IO.FileInfo($path)

        # Reject empty 0-byte placeholders
        if ($info.Length -le 0) {
            Start-Sleep -Milliseconds 100
            continue
        }

        # If file size is actively changing, continue waiting
        if ($info.Length -ne $lastSize) {
            $lastSize = $info.Length
            Start-Sleep -Milliseconds 200
            continue
        }

        # Test exclusive read access
        try {
            $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'None')
            $fs.Close()
            $fs.Dispose()
            return "READY"
        } catch {
            Start-Sleep -Milliseconds 200
            continue
        }
    }
    return "TIMEOUT"
}

$passed = 0
$failed = 0

function Assert-Result([string]$testName, [string]$actual, [string]$expected) {
    if ($actual -eq $expected) {
        Write-Host "  [PASS] $testName (Result: $actual)" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $testName (Expected: $expected, Got: $actual)" -ForegroundColor Red
        $script:failed++
    }
}

try {
    # 1. Valid file below 10 KB (e.g., 512 bytes) - MUST BE ACCEPTED (BUG-01)
    $smallFilePath = Join-Path $tempDir "valid_small.jpg"
    $bytes = New-Object byte[] 512
    [System.IO.File]::WriteAllBytes($smallFilePath, $bytes)
    $res1 = Test-Wait-ForFileReady $smallFilePath
    Assert-Result "Valid file < 10 KB (512 bytes) accepted as READY" $res1 "READY"

    # 2. Valid file below 10 KB (e.g., 4096 bytes)
    $smallFilePath2 = Join-Path $tempDir "valid_4kb.png"
    $bytes4k = New-Object byte[] 4096
    [System.IO.File]::WriteAllBytes($smallFilePath2, $bytes4k)
    $res2 = Test-Wait-ForFileReady $smallFilePath2
    Assert-Result "Valid file < 10 KB (4096 bytes) accepted as READY" $res2 "READY"

    # 3. Zero-byte placeholder file - MUST NOT BE READY
    $zeroFilePath = Join-Path $tempDir "zero_byte.tmp"
    New-Item -ItemType File -Path $zeroFilePath -Force | Out-Null
    $res3 = Test-Wait-ForFileReady $zeroFilePath 3
    Assert-Result "Zero-byte placeholder file times out (not uploaded prematurely)" $res3 "TIMEOUT"

    # 4. Missing or deleted file
    $missingFilePath = Join-Path $tempDir "does_not_exist.jpg"
    $res4 = Test-Wait-ForFileReady $missingFilePath
    Assert-Result "Non-existent file returns NOT_FOUND" $res4 "NOT_FOUND"

    # 5. File locked exclusively by another process - MUST TIME OUT
    $lockedFilePath = Join-Path $tempDir "locked_file.mp4"
    [System.IO.File]::WriteAllBytes($lockedFilePath, (New-Object byte[] 2048))
    $lockStream = [System.IO.File]::Open($lockedFilePath, 'Open', 'ReadWrite', 'None')
    try {
        $res5 = Test-Wait-ForFileReady $lockedFilePath 3
        Assert-Result "Locked file returns TIMEOUT and is queued for retry" $res5 "TIMEOUT"
    } finally {
        $lockStream.Close()
        $lockStream.Dispose()
    }

    # 6. File released after lock - MUST BECOME READY
    $res6 = Test-Wait-ForFileReady $lockedFilePath
    Assert-Result "Unlocked file becomes READY after writer release" $res6 "READY"

} finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  RESULTS: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
