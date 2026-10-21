$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$watcher = Join-Path $root "WatchAndUpload.ps1"
$trayScript = Join-Path $root "PhotosTray.ps1"
$vbs = Join-Path $root "StartPhotosWatcher.vbs"
$watchList = Join-Path $root "watch-folders.txt"
$config = Join-Path $root "gotohp.config"
$gui = Join-Path $root "gotohp-x64.exe"
$cli = @("gotohp-cli-x64.exe", "gotohp-cli.exe") |
    ForEach-Object { Join-Path $root $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
$powershell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
$wscript = Join-Path $env:WINDIR "System32\wscript.exe"
$startup = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)

function Get-PhotoRelayProcess([string]$pattern) {
    try {
        @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.Name -in @("powershell.exe", "pwsh.exe") -and $_.CommandLine -like $pattern
        })
    } catch {
        Write-Warning "Windows process inspection is unavailable; the launch guard will still prevent duplicates of this version."
        @()
    }
}

function Set-StartupShortcut([string]$name, [string]$target, [string]$arguments, [string]$description) {
    $path = Join-Path $startup $name
    $shortcut = $shell.CreateShortcut($path)
    $shortcut.TargetPath = $target
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = $root
    $shortcut.Description = $description
    $shortcut.Save()
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Could not create Startup shortcut: $path"
    }
}

Write-Host "PhotoRelay-Windows setup" -ForegroundColor Cyan
Write-Host "Folder: $root"

foreach ($required in @($watcher, $trayScript, $vbs)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required file is missing: $required"
    }
}
if (-not $cli) { throw "gotohp CLI was not found in $root" }
if (-not (Test-Path -LiteralPath $startup -PathType Container)) {
    throw "Windows Startup folder was not found: $startup"
}

if (-not (Test-Path -LiteralPath $watchList -PathType Leaf)) {
    $defaultWatchFolder = Join-Path $env:USERPROFILE "Pictures"
    if (-not (Test-Path -LiteralPath $defaultWatchFolder -PathType Container)) {
        New-Item -ItemType Directory -Path $defaultWatchFolder -Force | Out-Null
    }
    Set-Content -LiteralPath $watchList -Value $defaultWatchFolder -Encoding UTF8
    Write-Host "Created default watch folder: $defaultWatchFolder" -ForegroundColor Green
} else {
    Write-Host "Keeping the existing watch-folders.txt unchanged." -ForegroundColor Green
}

$cliArgs = @()
if (Test-Path -LiteralPath $config -PathType Leaf) { $cliArgs += @("--config", $config) }
$account = (& $cli @cliArgs creds list 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $account -match "No credentials found" -or $account -notmatch "\*") {
    if (-not (Test-Path -LiteralPath $gui -PathType Leaf)) {
        throw "Google sign-in is needed, but gotohp-x64.exe was not found."
    }
    Write-Host "Sign in in the gotohp window. Close it after the account connects; setup will continue." -ForegroundColor Yellow
    Start-Process -FilePath $gui -WorkingDirectory $root -Wait
    $account = (& $cli @cliArgs creds list 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $account -match "No credentials found" -or $account -notmatch "\*") {
        throw "No connected Google account was found after sign-in."
    }
}

$shell = New-Object -ComObject WScript.Shell
Set-StartupShortcut "PhotoRelay-Windows Uploader.lnk" $wscript ('//B "' + $vbs + '"') "Start PhotoRelay-Windows uploader"
Set-StartupShortcut "PhotoRelay-Windows Tray.lnk" $powershell ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $trayScript + '"') "Show PhotoRelay-Windows upload status"

# Migrate old startup links only when their targets point into this checkout.
$canonicalUploader = Join-Path $startup "PhotoRelay-Windows Uploader.lnk"
$canonicalTray = Join-Path $startup "PhotoRelay-Windows Tray.lnk"
$duplicateShortcuts = @()
foreach ($entry in Get-ChildItem -LiteralPath $startup -Filter "*.lnk" -File) {
    if ($entry.FullName -in @($canonicalUploader, $canonicalTray)) { continue }
    $old = $shell.CreateShortcut($entry.FullName)
    $targetText = "$($old.TargetPath) $($old.Arguments)"
    $targetsThisProject = $targetText.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0
    $targetsOurScripts = $targetText -match "(?i)StartPhotosWatcher\.vbs|WatchAndUpload\.ps1|GooglePhotosTray\.ps1|PhotosTray\.ps1"
    if ($targetsThisProject -and $targetsOurScripts) {
        $duplicateShortcuts += [pscustomobject]@{ Path = $entry.FullName; Target = $targetText }
    }
}
if ($duplicateShortcuts.Count -gt 0) {
    foreach ($shortcut in $duplicateShortcuts) {
        Remove-Item -LiteralPath $shortcut.Path -Force -ErrorAction Stop
    }
    Write-Host "Removed $($duplicateShortcuts.Count) older startup shortcut(s) for this folder." -ForegroundColor Green
}

$uploaders = @(Get-PhotoRelayProcess "*WatchAndUpload.ps1*")
$currentUploaders = @($uploaders | Where-Object {
    $_.CommandLine.IndexOf($watcher, [StringComparison]::OrdinalIgnoreCase) -ge 0
})
$keepUploader = $null
if ($currentUploaders.Count -gt 0) {
    $keepUploader = $currentUploaders | Sort-Object CreationDate | Select-Object -First 1
}
$staleUploaders = @($uploaders | Where-Object {
    -not $keepUploader -or $_.ProcessId -ne $keepUploader.ProcessId
})
$allowUploaderLaunch = $true
if ($staleUploaders.Count -gt 0) {
    Write-Host "Existing duplicate uploader processes:" -ForegroundColor Yellow
    $staleUploaders | Select-Object ProcessId, CreationDate, CommandLine | Format-List
    foreach ($process in $staleUploaders) { Stop-Process -Id $process.ProcessId -WhatIf }
    $answer = Read-Host "Type STOP to end only those listed duplicate uploaders (an in-progress upload will retry)"
    if ($answer -ceq "STOP") {
        foreach ($process in $staleUploaders) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        }
    } else {
        Write-Warning "Left existing processes running; no additional uploader was started."
        $allowUploaderLaunch = $false
    }
}

if ($keepUploader) {
    Write-Host "Uploader already running (PID $($keepUploader.ProcessId)); not starting another." -ForegroundColor Yellow
} elseif ($allowUploaderLaunch) {
    Write-Host "Starting uploader..."
    Start-Process -FilePath $wscript -ArgumentList ('//B "' + $vbs + '"') -WorkingDirectory $root
}
$trays = @(Get-PhotoRelayProcess "*PhotosTray.ps1*")
if ($trays.Count -eq 0) {
    Write-Host "Starting tray icon..."
    $trayArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $trayScript + '"'
    Start-Process -FilePath $powershell -ArgumentList $trayArguments -WorkingDirectory $root -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $trays = @(Get-PhotoRelayProcess "*PhotosTray.ps1*")
}
if ($trays.Count -eq 0) {
    Write-Warning "Tray process did not remain open. Run PhotosTray.ps1 from PowerShell to see its startup error."
} else {
    Write-Host "Tray running (PID $($trays[0].ProcessId))." -ForegroundColor Green
}

Write-Host "Setup complete. The uploader and tray will start at Windows sign-in." -ForegroundColor Green

