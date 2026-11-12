$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WatchAndUpload.ps1'), [ref]$tokens, [ref]$errors)
foreach ($name in @('Get-FileHashSafe', 'Invoke-Upload')) {
    $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $fn) { throw "Missing $name" }
    Invoke-Expression $fn.Extent.Text
}
$script:EXT = New-Object 'System.Collections.Generic.HashSet[string]'; [void]$script:EXT.Add('.jpg')
$script:history = New-Object 'System.Collections.Generic.HashSet[string]'
$script:fileLookup = New-Object 'System.Collections.Generic.HashSet[string]'
$script:inFlight = New-Object 'System.Collections.Generic.HashSet[string]'
$script:retryMap = New-Object 'System.Collections.Generic.Dictionary[string,int]'
$script:GOTOHP = Join-Path $env:TEMP ('missing-' + [guid]::NewGuid().ToString('N') + '.exe')
$script:CONFIG_ARGS = @(); $script:MAX_RETRY = 3
function Set-TrayStatus($status) { }
function Wait-ForFileReady($path) { 'READY' }
function Write-Log($message, $level) { }
function Save-Retry($path, $attempts) { $script:retryMap[$path] = $attempts }
function Remove-Retry($path) { [void]$script:retryMap.Remove($path) }
$file = Join-Path $env:TEMP ('photorelay-exception-' + [guid]::NewGuid().ToString('N') + '.jpg')
try {
    [System.IO.File]::WriteAllText($file, 'fixture')
    Invoke-Upload $file
    if (-not $script:retryMap.ContainsKey($file)) { throw 'A failed upload process start was not queued for retry.' }
    if ($script:retryMap[$file] -ne 1) { throw 'The failed upload did not count as one attempt.' }
    Invoke-Upload $file
    if ($script:retryMap[$file] -ne 2) { throw 'The second failure did not increment the retry count.' }
    Invoke-Upload $file
    if ($script:retryMap.ContainsKey($file)) { throw 'The third failure did not exhaust retries.' }
    Write-Host '[PASS] An upload process start error is queued for retry.'
} finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
