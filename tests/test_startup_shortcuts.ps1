$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WatchAndUpload.ps1'), [ref]$tokens, [ref]$errors)
$fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Disable-PhotoRelayStartup' }, $true)
if (-not $fn) { throw 'Startup disable helper is missing.' }
Invoke-Expression $fn.Extent.Text
$enable = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Enable-PhotoRelayStartup' }, $true)
if (-not $enable) { throw 'Startup enable helper is missing.' }
Invoke-Expression $enable.Extent.Text
$temp = Join-Path $env:TEMP ('photorelay-startup-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $script:BASE = Join-Path $temp 'project'
    $startup = Join-Path $temp 'startup'
    New-Item -ItemType Directory -Path $script:BASE, $startup | Out-Null
    $ws = New-Object -ComObject WScript.Shell
    foreach ($entry in @(
        @{Name='PhotoRelay-Windows Uploader.lnk'; Target=(Join-Path $env:WINDIR 'System32\wscript.exe'); Args=('//B "' + (Join-Path $script:BASE 'StartPhotosWatcher.vbs') + '"')},
        @{Name='PhotoRelay-Windows Tray.lnk'; Target=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'); Args=('-File "' + (Join-Path $script:BASE 'PhotosTray.ps1') + '"')},
        @{Name='PhotoRelay-Windows.lnk'; Target=(Join-Path $temp 'other\StartPhotosWatcher.vbs'); Args=''}
    )) {
        $shortcut = $ws.CreateShortcut((Join-Path $startup $entry.Name))
        $shortcut.TargetPath = $entry.Target
        $shortcut.Arguments = $entry.Args
        $shortcut.Save()
    }
    Disable-PhotoRelayStartup $startup
    if (Test-Path (Join-Path $startup 'PhotoRelay-Windows Uploader.lnk')) { throw 'Uploader shortcut remains.' }
    if (Test-Path (Join-Path $startup 'PhotoRelay-Windows Tray.lnk')) { throw 'Tray shortcut remains.' }
    if (-not (Test-Path (Join-Path $startup 'PhotoRelay-Windows.lnk'))) { throw 'Another installation shortcut was removed.' }
    Write-Host '[PASS] Disable removes only this installation startup shortcuts'
    Enable-PhotoRelayStartup $startup
    if (-not (Test-Path (Join-Path $startup 'PhotoRelay-Windows Uploader.lnk'))) { throw 'Uploader shortcut was not created.' }
    if (-not (Test-Path (Join-Path $startup 'PhotoRelay-Windows Tray.lnk'))) { throw 'Tray shortcut was not created.' }
    Write-Host '[PASS] Enable creates uploader and tray startup shortcuts'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
