$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WatchAndUpload.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Watcher parse failed.' }
$fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-PhotoRelayTray' }, $true)
if (-not $fn) { throw 'Watcher does not start the tray.' }
Invoke-Expression $fn.Extent.Text
$script:BASE = Join-Path $env:TEMP 'PhotoRelay test folder'
function Start-Process { param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle) $script:launch = $PSBoundParameters }
Start-PhotoRelayTray
if ($script:launch.FilePath -ne (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')) { throw 'Wrong PowerShell host.' }
if ($script:launch.ArgumentList -notmatch '-STA' -or -not $script:launch.ArgumentList.Contains(('"' + (Join-Path $script:BASE 'PhotosTray.ps1') + '"'))) { throw 'Tray script or STA argument missing.' }
if ($script:launch.WindowStyle -ne 'Hidden' -or $script:launch.WorkingDirectory -ne $script:BASE) { throw 'Tray is not launched hidden in the project folder.' }
$calls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-PhotoRelayTray' }, $true))
if ($calls.Count -ne 1) { throw 'Watcher must launch the tray once on the normal watch path.' }
$text = [System.IO.File]::ReadAllText((Join-Path $root 'WatchAndUpload.ps1'))
if ($calls[0].Extent.StartOffset -le $text.IndexOf('if ($ShowLogs) {') -or $calls[0].Extent.StartOffset -ge $text.IndexOf('# PHASE 1 - Startup scan')) { throw 'Tray launch is outside the watch path.' }
Write-Host '[PASS] Watcher starts the tray hidden with the expected script and host.'
