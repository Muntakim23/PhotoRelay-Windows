
@echo off
setlocal
cd /d "%~dp0"
set "CONFIG=%~dp0watch-folders.txt"

if not exist "%CONFIG%" type nul > "%CONFIG%"

:menu
cls
echo ========================================
echo       PHOTORELAY FOLDER MANAGER
echo ========================================
echo.
echo All backup folders
powershell -NoProfile -Command "$i=0; Get-Content -LiteralPath $env:CONFIG | Where-Object { $_.Trim() } | ForEach-Object { $i++; Write-Host ('  {0}. {1}' -f $i, $_) }"
echo.
echo ========================================
echo 1. Add a new folder
echo 2. Delete a folder
echo 3. Exit
echo ========================================
echo.
set "choice="
set /p "choice=Choose an option: "
if "%choice%"=="1" goto add
if "%choice%"=="2" goto delete
if "%choice%"=="3" exit /b
goto menu

:add
echo.
set "NEWFOLDER="
set /p "NEWFOLDER=Enter the full folder path: "
if not defined NEWFOLDER goto menu
powershell -NoProfile -Command "$p=$env:NEWFOLDER; if (-not (Test-Path -LiteralPath $p -PathType Container)) { Write-Host 'ERROR: Folder does not exist.'; exit 1 }; $p=(Resolve-Path -LiteralPath $p).Path; $f=@(Get-Content -LiteralPath $env:CONFIG | Where-Object { $_.Trim() }); if ($f -contains $p) { Write-Host 'This folder is already listed.'; exit 1 }; Add-Content -LiteralPath $env:CONFIG -Value $p; Write-Host 'Folder added successfully.'"
pause
goto menu

:delete
echo.
set "DELNUM="
set /p "DELNUM=Enter the number of the folder to remove: "
if not defined DELNUM goto menu
powershell -NoProfile -Command "$f=@(Get-Content -LiteralPath $env:CONFIG | Where-Object { $_.Trim() }); $n=0; if (-not [int]::TryParse($env:DELNUM,[ref]$n) -or $n -lt 1 -or $n -gt $f.Count) { Write-Host 'Invalid folder number.'; exit 1 }; Write-Host ('Selected: ' + $f[$n-1]); $confirm=Read-Host 'Remove this folder from monitoring? Type YES to confirm'; if ($confirm -cne 'YES') { Write-Host 'Cancelled.'; exit 0 }; $remaining=@(for($i=0;$i -lt $f.Count;$i++){if($i -ne ($n-1)){$f[$i]}}); Set-Content -LiteralPath $env:CONFIG -Value $remaining -Encoding UTF8; Write-Host 'Folder removed from the configuration.'"
pause
goto menu
