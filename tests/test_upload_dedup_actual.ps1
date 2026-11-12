$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path $env:TEMP ('photorelay-dedup-actual-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    Import-Module (Join-Path $root 'Modules\PSSQLite\PSSQLite.psd1') -Force
    $exe = Join-Path $temp 'mock.exe'
    $mockSource = 'public class MockUpload { public static int Main(string[] args) { return 0; } }'
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $env:PHOTORELAY_TEST_MOCK_EXE = $exe
        $compile = "Add-Type -TypeDefinition '$mockSource' -OutputAssembly `$env:PHOTORELAY_TEST_MOCK_EXE -OutputType ConsoleApplication"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($compile))
        & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -EncodedCommand $encoded
        if ($LASTEXITCODE -ne 0) { throw 'Could not build the test uploader.' }
    } else {
        Add-Type -TypeDefinition $mockSource -OutputAssembly $exe -OutputType ConsoleApplication
    }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WatchAndUpload.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Watcher parse failed.' }
    foreach ($name in @('Get-FileHashSafe', 'Format-WindowsArgument', 'Invoke-Upload')) {
        $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if (-not $fn) { throw "Missing function: $name" }
        Invoke-Expression $fn.Extent.Text
    }
    $script:DB = Join-Path $temp 'test.db'
    Invoke-SqliteQuery -DataSource $script:DB -Query 'CREATE TABLE uploads (path TEXT, file_name TEXT, file_size INTEGER, content_hash TEXT)' | Out-Null
    $script:EXT = New-Object 'System.Collections.Generic.HashSet[string]'; [void]$script:EXT.Add('.jpg')
    $script:history = New-Object 'System.Collections.Generic.HashSet[string]'
    $script:fileLookup = New-Object 'System.Collections.Generic.HashSet[string]'; [void]$script:fileLookup.Add('sample.jpg|4')
    $script:inFlight = New-Object 'System.Collections.Generic.HashSet[string]'
    $script:retryMap = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $script:GOTOHP = $exe; $script:CONFIG_ARGS = @(); $script:MAX_RETRY = 3
    function Wait-ForFileReady($path) { if ($script:changeBeforeReady) { [System.IO.File]::WriteAllText($path, 'BBBB') }; 'READY' }
    function Set-TrayStatus($status) { }
    function Safe-ConsoleWrite($message) { }
    function Write-Log($message, $level) { }
    function Save-Retry($path, $attempts) { }
    function Remove-Retry($path) { }
    function Save-Upload($path, $key, $name, $size, $hash) { $script:savedKey = $key; return $true }
    function Schedule-DeleteAfterBackup($path, $hash, $size) { }
    $file = Join-Path $temp 'sample.jpg'; $other = Join-Path $temp 'other.jpg'
    [System.IO.File]::WriteAllText($file, 'AAAA'); [System.IO.File]::WriteAllText($other, 'BBBB')
    $sameHash = Get-FileHashSafe $file; $otherHash = Get-FileHashSafe $other
    $failures = @()
    foreach ($case in @('different', 'legacy', 'multiple', 'changed-before-ready')) {
        [System.IO.File]::WriteAllText($file, 'AAAA')
        $script:changeBeforeReady = $case -eq 'changed-before-ready'
        Invoke-SqliteQuery -DataSource $script:DB -Query 'DELETE FROM uploads' | Out-Null
        if ($case -eq 'legacy') {
            Invoke-SqliteQuery -DataSource $script:DB -Query "INSERT INTO uploads VALUES ('old', 'sample.jpg', 4, NULL)" | Out-Null
        } else {
            $firstHash = if ($case -eq 'changed-before-ready') { $sameHash } else { $otherHash }
            Invoke-SqliteQuery -DataSource $script:DB -Query "INSERT INTO uploads VALUES ('old', 'sample.jpg', 4, @hash)" -SqlParameters @{hash=$firstHash} | Out-Null
            if ($case -eq 'multiple') {
                Invoke-SqliteQuery -DataSource $script:DB -Query "INSERT INTO uploads VALUES ('matching', 'sample.jpg', 4, @hash)" -SqlParameters @{hash=$sameHash} | Out-Null
            }
        }
        $script:savedKey = 'NOT_CALLED'
        Invoke-Upload $file
        $expected = if ($case -eq 'multiple') { 'DUAL_BOOT_SYNC' } else { '' }
        if ($script:savedKey -ne $expected) { $failures += "$case chose '$script:savedKey', expected '$expected'" }
        if ($case -eq 'legacy') {
            $old = Invoke-SqliteQuery -DataSource $script:DB -Query "SELECT content_hash FROM uploads WHERE path = 'old'"
            if ($null -ne $old.content_hash -and $old.content_hash -ne [DBNull]::Value) { $failures += 'legacy hash was changed' }
        }
    }
    if ($failures.Count) { throw ($failures -join '; ') }
    Write-Host '[PASS] Actual upload logic checks all hashes and leaves legacy records unchanged.'
} finally {
    Remove-Item Env:PHOTORELAY_TEST_MOCK_EXE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
