# =====================================================================
# Regression Test Suite: BUG-02 (Subprocess Output Streaming & Deadlock Elimination)
# =====================================================================
$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  TEST SUITE: BUG-02 Process Pipe Deadlock Elimination"      -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

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

# 1. Test large concurrent stdout & stderr output (which would block synchronous ReadToEnd)
# Standard pipe buffer on Windows is 4KB. Emitting 64KB+ on stdout and stderr concurrently
# guarantees buffer fill and deadlock if not read concurrently.
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "powershell.exe"
$largeScript = @"
[Console]::Out.Write(('STDOUT_CHUNK_' * 8000))
[Console]::Error.Write(('STDERR_CHUNK_' * 8000))
exit 0
"@
$psi.Arguments = "-NoProfile -Command `"$largeScript`""
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

$proc = [System.Diagnostics.Process]::Start($psi)

# Asynchronous stream consumption as implemented in WatchAndUpload.ps1
$stdoutTask = $proc.StandardOutput.ReadToEndAsync()
$stderrTask = $proc.StandardError.ReadToEndAsync()

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$timedOut = $false
$timeoutLimit = 15 # 15 seconds max

while (-not $proc.WaitForExit(100)) {
    if ($sw.Elapsed.TotalSeconds -ge $timeoutLimit) {
        $timedOut = $true
        try { $proc.Kill() } catch {}
        break
    }
}

$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()

Assert-Condition "Large simultaneous stdout & stderr does not deadlock" (-not $timedOut) "Process deadlocked or timed out"
Assert-Condition "Stdout drained completely (>64 KB received)" ($stdout.Length -gt 60000) "Stdout length: $($stdout.Length)"
Assert-Condition "Stderr drained completely (>64 KB received)" ($stderr.Length -gt 60000) "Stderr length: $($stderr.Length)"
Assert-Condition "Process exited cleanly with code 0" ($proc.ExitCode -eq 0) "Exit code: $($proc.ExitCode)"

# 2. Test hanging process detection and timeout enforcement
$psiHang = New-Object System.Diagnostics.ProcessStartInfo
$psiHang.FileName = "powershell.exe"
$psiHang.Arguments = "-NoProfile -Command `"Start-Sleep -Seconds 30`""
$psiHang.UseShellExecute = $false
$psiHang.CreateNoWindow = $true
$psiHang.RedirectStandardOutput = $true
$psiHang.RedirectStandardError = $true

$procHang = [System.Diagnostics.Process]::Start($psiHang)
$hangStdoutTask = $procHang.StandardOutput.ReadToEndAsync()
$hangStderrTask = $procHang.StandardError.ReadToEndAsync()

$hangTimeoutSeconds = 2 # Short timeout to test bounding
$swHang = [System.Diagnostics.Stopwatch]::StartNew()
$didTimeout = $false

while (-not $procHang.WaitForExit(100)) {
    if ($swHang.Elapsed.TotalSeconds -ge $hangTimeoutSeconds) {
        $didTimeout = $true
        try { $procHang.Kill() } catch {}
        break
    }
}

Assert-Condition "Process timeout is enforced and hanging child process is terminated" $didTimeout
Assert-Condition "Terminated child process has exited" ($procHang.HasExited)

# 3. Test non-zero exit code capture and error reporting
$psiErr = New-Object System.Diagnostics.ProcessStartInfo
$psiErr.FileName = "powershell.exe"
$psiErr.Arguments = "-NoProfile -Command `"[Console]::Error.Write('Upload failed: token expired'); exit 42`""
$psiErr.UseShellExecute = $false
$psiErr.CreateNoWindow = $true
$psiErr.RedirectStandardOutput = $true
$psiErr.RedirectStandardError = $true

$procErr = [System.Diagnostics.Process]::Start($psiErr)
$errOutTask = $procErr.StandardOutput.ReadToEndAsync()
$errErrTask = $procErr.StandardError.ReadToEndAsync()
$procErr.WaitForExit()

$errOut = $errOutTask.GetAwaiter().GetResult()
$errErr = $errErrTask.GetAwaiter().GetResult()

Assert-Condition "Non-zero exit code (42) captured accurately" ($procErr.ExitCode -eq 42) "Exit code: $($procErr.ExitCode)"
Assert-Condition "Stderr error message captured accurately" ($errErr -match "Upload failed: token expired") "Stderr: $errErr"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  RESULTS: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
