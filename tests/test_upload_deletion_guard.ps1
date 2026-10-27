$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path $env:TEMP ('photorelay-guard-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $source = @'
using System;
using System.IO;
public class MockUpload {
  public static int Main(string[] args) {
    if (Environment.GetEnvironmentVariable("PHOTORELAY_TEST_CHANGE") == "1")
      File.WriteAllText(args[args.Length - 1], "changed");
    return 0;
  }
}
'@
    $exe = Join-Path $temp 'mock.exe'
    Add-Type -TypeDefinition $source -OutputAssembly $exe -OutputType ConsoleApplication
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WatchAndUpload.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Watcher parse failed.' }
    foreach ($name in @('Get-FileHashSafe', 'Format-WindowsArgument', 'Invoke-Upload')) {
        $func = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if (-not $func) { throw "Function missing: $name" }
        Invoke-Expression $func.Extent.Text
    }
    $script:EXT = New-Object 'System.Collections.Generic.HashSet[string]'
    [void]$script:EXT.Add('.jpg')
    $script:history = New-Object 'System.Collections.Generic.HashSet[string]'
    $script:fileLookup = New-Object 'System.Collections.Generic.HashSet[string]'
    $script:inFlight = New-Object 'System.Collections.Generic.HashSet[string]'
    $script:retryMap = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $script:GOTOHP = $exe; $script:CONFIG_ARGS = @(); $script:MAX_RETRY = 3
    function Wait-ForFileReady($path) { 'READY' }
    function Set-TrayStatus($status) { }
    function Safe-ConsoleWrite($message) { }
    function Write-Log($message, $level) { }
    function Save-Retry($path, $attempts) { }
    function Save-Upload($path, $key, $name, $size, $hash) { return $script:saved }
    function Schedule-DeleteAfterBackup($path, $hash, $size) { $script:scheduled++ }
    $file = Join-Path $temp 'sample.jpg'
    foreach ($case in @('save-fails', 'changed', 'unchanged')) {
        [System.IO.File]::WriteAllText($file, 'fixture')
        $script:scheduled = 0
        $script:saved = $case -ne 'save-fails'
        $env:PHOTORELAY_TEST_CHANGE = if ($case -eq 'changed') { '1' } else { '0' }
        Invoke-Upload $file
        $expected = if ($case -eq 'unchanged') { 1 } else { 0 }
        if ($script:scheduled -ne $expected) { throw "$case scheduled $($script:scheduled) deletion(s), expected $expected" }
        Write-Host "[PASS] $case"
    }
} finally {
    Remove-Item Env:PHOTORELAY_TEST_CHANGE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
