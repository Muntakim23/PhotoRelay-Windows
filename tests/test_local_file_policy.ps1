$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root "WatchAndUpload.ps1"
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Watcher script failed to parse." }
$function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Schedule-DeleteAfterBackup" }, $true)
if (-not $function) { throw "Deletion function not found." }
Invoke-Expression $function.Extent.Text
function Write-Log([string]$message, [string]$level) { }

$temp = Join-Path $env:TEMP ("photorelay-policy-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $script:BASE = $temp
    $policy = Join-Path $temp "local-file-policy.txt"
    $file = Join-Path $temp "sample.jpg"
    [System.IO.File]::WriteAllText($file, "fixture")
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    $length = (Get-Item -LiteralPath $file).Length
    $before = @(Get-Job -ErrorAction SilentlyContinue).Count
    Schedule-DeleteAfterBackup $file $hash $length
    if (@(Get-Job -ErrorAction SilentlyContinue).Count -ne $before) { throw "Missing setting scheduled deletion." }
    Set-Content -LiteralPath $policy -Value "invalid"
    Schedule-DeleteAfterBackup $file $hash $length
    if (@(Get-Job -ErrorAction SilentlyContinue).Count -ne $before) { throw "Invalid setting scheduled deletion." }
    Write-Host "[PASS] Missing and invalid settings keep files"

    $jobs = @()
    foreach ($case in @("delete", "switched", "changed")) {
        $dir = Join-Path $temp $case
        New-Item -ItemType Directory -Path $dir | Out-Null
        $script:BASE = $dir
        $path = Join-Path $dir "sample.jpg"
        [System.IO.File]::WriteAllText($path, "fixture")
        Set-Content -LiteralPath (Join-Path $dir "local-file-policy.txt") -Value "delete"
        Schedule-DeleteAfterBackup $path $hash $length
        $jobs += Get-Job -ErrorAction SilentlyContinue | Sort-Object Id | Select-Object -Last 1
    }
    Set-Content -LiteralPath (Join-Path $temp "switched\local-file-policy.txt") -Value "keep"
    [System.IO.File]::WriteAllText((Join-Path $temp "changed\sample.jpg"), "changed")
    $jobs | Wait-Job -Timeout 50 | Out-Null
    if (@($jobs | Where-Object { $_.State -ne 'Completed' }).Count) { throw "Deletion jobs did not complete successfully." }
    if (Test-Path -LiteralPath (Join-Path $temp "delete\sample.jpg")) { throw "Explicit delete mode did not delete the unchanged fixture." }
    if (-not (Test-Path -LiteralPath (Join-Path $temp "switched\sample.jpg"))) { throw "Switching to keep did not preserve the fixture." }
    if (-not (Test-Path -LiteralPath (Join-Path $temp "changed\sample.jpg"))) { throw "Changed fixture was deleted." }
    Write-Host "[PASS] Delete mode, switching to keep, and changed-file protection"
} finally {
    if ($jobs) { $jobs | Remove-Job -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
