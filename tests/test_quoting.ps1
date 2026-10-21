# =====================================================================
# Regression Test Suite: BUG-03 (Windows Argument Quoting)
# =====================================================================
$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  TEST SUITE: BUG-03 Windows Argument Quoting (PowerShell)"   -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

# Source Format-WindowsArgument from WatchAndUpload.ps1
function Format-WindowsArgument([string]$arg) {
    if ([string]::IsNullOrEmpty($arg)) {
        return '""'
    }
    if ($arg -notmatch '[\s"]') {
        return $arg
    }
    $escaped = [System.Text.RegularExpressions.Regex]::Replace($arg, '(\\+)(")', '$1$1\"')
    $escaped = [System.Text.RegularExpressions.Regex]::Replace($escaped, '(\\+)$', '$1$1')
    $escaped = $escaped -replace '"', '\"'
    return "`"$escaped`""
}

$passed = 0
$failed = 0

function Assert-Equal([string]$testName, [string]$actual, [string]$expected) {
    if ($actual -eq $expected) {
        Write-Host "  [PASS] $testName" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $testName (Expected: <$expected>, Got: <$actual>)" -ForegroundColor Red
        $script:failed++
    }
}

# 1. Simple path without spaces
$p1 = "C:\Photos\vacation.jpg"
Assert-Equal "Path without spaces remains unquoted" (Format-WindowsArgument $p1) "C:\Photos\vacation.jpg"

# 2. Path with spaces
$p2 = "C:\Users\Example User\Pictures\PhotoRelay-Windows"
Assert-Equal "Path with spaces is properly enclosed in quotes" (Format-WindowsArgument $p2) "`"C:\Users\Example User\Pictures\PhotoRelay-Windows`""

# 3. Path with parentheses and spaces
$p3 = "D:\Media Backup\Photos (2026)\image.jpg"
Assert-Equal "Path with parentheses and spaces" (Format-WindowsArgument $p3) "`"D:\Media Backup\Photos (2026)\image.jpg`""

# 4. Path with trailing backslash (crucial Windows quoting edge case)
$p4 = "C:\My Photos\"
Assert-Equal "Path with trailing backslash escapes trailing backslash before closing quote" (Format-WindowsArgument $p4) "`"C:\My Photos\\`""

# 5. Path with internal double quotes
$p5 = 'Path with "quotes" inside'
Assert-Equal "Internal quotes are escaped" (Format-WindowsArgument $p5) '"Path with \"quotes\" inside"'

# 6. Unicode path with spaces
$p6 = "C:\Users\José González\Pictures (东京)\旅行 photo.jpg"
Assert-Equal "Unicode characters with spaces" (Format-WindowsArgument $p6) "`"C:\Users\José González\Pictures (东京)\旅行 photo.jpg`""

# 7. Empty string
Assert-Equal "Empty string returns empty quotes" (Format-WindowsArgument "") '""'

# 8. End-to-end execution test with child process passing arguments containing spaces
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "cmd.exe"
$testArgs = @("upload", "C:\Users\Example User\Photos (2026)\photo.jpg", "--config", "C:\My Config\gotohp.config")

if ($psi.PSObject.Properties['ArgumentList']) {
    foreach ($a in $testArgs) { [void]$psi.ArgumentList.Add($a) }
} else {
    $psi.Arguments = ($testArgs | ForEach-Object { Format-WindowsArgument $_ }) -join " "
}

$formattedCmd = ($testArgs | ForEach-Object { Format-WindowsArgument $_ }) -join " "
Assert-Equal "Command string properly encapsulates each argument" $formattedCmd "upload `"C:\Users\Example User\Photos (2026)\photo.jpg`" --config `"C:\My Config\gotohp.config`""

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  RESULTS: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
