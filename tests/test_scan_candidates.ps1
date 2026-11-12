$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WatchAndUpload.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Watcher parse failed.' }
$filters = @($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Where-Object' -and $node.Extent.Text -match 'script:EXT\.Contains'
}, $true))
if ($filters.Count -ne 2) { throw "Expected the startup and safety scan filters, found $($filters.Count)." }
$script:EXT = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
[void]$script:EXT.Add('.jpg')
$script:history = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:fileLookup = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:inFlight = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
[void]$script:fileLookup.Add('same.jpg|4')
$candidate = [pscustomobject]@{ Extension='.jpg'; FullName='C:\other\same.jpg'; Name='same.jpg'; Length=4; LastWriteTime=[DateTime]::Now }
foreach ($filter in $filters) {
    $predicate = $filter.CommandElements[1].ScriptBlock.GetScriptBlock()
    if (-not @($candidate | Where-Object $predicate).Count) { throw 'Scan discarded a same-name, same-size candidate before checking its content.' }
}
Write-Host '[PASS] Both scans pass name-and-size collisions to the content check.'
