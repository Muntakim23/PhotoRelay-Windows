# =====================================================================
# Comprehensive Test Runner: Windows (PowerShell)
# =====================================================================
$ErrorActionPreference = "Stop"

$testFiles = @(
    "test_readiness.ps1",
    "test_quoting.ps1",
    "test_deadlock.ps1",
    "test_dedup.ps1",
    "test_persistence.ps1",
    "test_single_instance.ps1"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$testHost = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" })
$totalPassed = 0
$totalFailed = 0

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  PhotoRelay-Windows - Windows Regression Test Suite"         -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

foreach ($testName in $testFiles) {
    $testPath = Join-Path $scriptDir $testName
    Write-Host "`n>>> Running: $testName" -ForegroundColor Yellow
    & $testHost -NoProfile -File $testPath
    if ($LASTEXITCODE -eq 0) {
        $totalPassed++
    } else {
        $totalFailed++
        Write-Host "FAILED: $testName" -ForegroundColor Red
    }
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  FINAL SUMMARY: $totalPassed Suites Passed, $totalFailed Suites Failed" -ForegroundColor $(if ($totalFailed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($totalFailed -gt 0) { exit 1 } else { exit 0 }
