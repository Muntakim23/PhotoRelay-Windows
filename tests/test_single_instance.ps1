$ErrorActionPreference = "Stop"
$name = "Local\PhotoRelayTest_$([guid]::NewGuid().ToString('N'))"
$first = New-Object System.Threading.Mutex($false, $name)
$firstOwns = $false

function Test-MutexFromChildProcess([string]$mutexName) {
    $source = @'
$mutex = New-Object System.Threading.Mutex($false, $env:PHOTORELAY_TEST_MUTEX)
$exitCode = 1
try {
    if ($mutex.WaitOne(0)) {
        $mutex.ReleaseMutex()
        $exitCode = 0
    }
} finally {
    $mutex.Dispose()
}
exit $exitCode
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($source))
    $priorName = $env:PHOTORELAY_TEST_MUTEX
    $env:PHOTORELAY_TEST_MUTEX = $mutexName
    try {
        $childHost = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" })
        $child = Start-Process -FilePath $childHost -ArgumentList @(
            "-NoProfile", "-EncodedCommand", $encoded
        ) -PassThru -Wait -WindowStyle Hidden
    } finally {
        $env:PHOTORELAY_TEST_MUTEX = $priorName
    }
    return ($child.ExitCode -eq 0)
}

try {
    $firstOwns = $first.WaitOne(0)
    if (-not $firstOwns) { throw "First instance could not acquire the mutex." }

    if (Test-MutexFromChildProcess $name) { throw "Second process acquired a mutex already held by the first." }

    $first.ReleaseMutex()
    $firstOwns = $false
    if (-not (Test-MutexFromChildProcess $name)) { throw "Mutex was not released for the next process." }

    $root = Split-Path -Parent $PSScriptRoot
    $checks = @{
        "WatchAndUpload.ps1" = "Local\PhotoRelayWatcher"
        "PhotosTray.ps1" = "Local\PhotoRelayTray"
    }
    foreach ($file in $checks.Keys) {
        $text = [System.IO.File]::ReadAllText((Join-Path $root $file))
        if (-not $text.Contains($checks[$file]) -or -not $text.Contains("ReleaseMutex")) {
            throw "$file is missing its singleton mutex acquire/release path."
        }
    }

    Write-Host "[PASS] Windows named mutex allows only one owner and is released cleanly." -ForegroundColor Green
} finally {
    if ($firstOwns) { try { $first.ReleaseMutex() } catch {} }
    $first.Dispose()
}
