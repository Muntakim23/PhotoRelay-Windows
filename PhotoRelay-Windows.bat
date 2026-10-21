@echo off
title PhotoRelay-Windows
cd /d "%~dp0"

set "PS_CMD=powershell.exe -NoProfile -ExecutionPolicy Bypass"
where pwsh.exe >nul 2>&1
if %ERRORLEVEL% equ 0 set "PS_CMD=pwsh.exe -NoProfile -ExecutionPolicy Bypass"

set "IS_MENU=0"
if "%~1"=="" (
    set "IS_MENU=1"
    goto menu
) else (
    goto handle_arg
)

:menu
cls
echo ==========================================================
echo   *  PhotoRelay-Windows (Windows)
echo ==========================================================
echo   [1] Start Live Watcher (Interactive progress)
echo   [2] Start Background Watcher (Silent, zero window)
echo   [3] Check Backup Status
echo   [4] View Activity Logs
echo   [5] Enable Auto-Start on Windows Boot
echo   [6] Disable Auto-Start on Windows Boot
echo   [7] Stop Background Watcher
echo   [0] Exit
echo ==========================================================
set "choice="
set /p "choice=Select an option [1-7, Default: 1]: "
if "%choice%"=="" set "choice=1"
if "%choice%"=="1" goto run_watcher
if "%choice%"=="2" goto run_silent
if "%choice%"=="3" goto check_status
if "%choice%"=="4" goto view_logs
if "%choice%"=="5" goto enable_startup
if "%choice%"=="6" goto disable_startup
if "%choice%"=="7" goto stop_watcher
if "%choice%"=="0" exit /b 0
echo Invalid option.
timeout /t 2 >nul
goto menu

:handle_arg
set "arg=%~1"
if /i "%arg%"=="watch" goto run_watcher
if /i "%arg%"=="run" goto run_watcher
if /i "%arg%"=="1" goto run_watcher
if /i "%arg%"=="silent" goto run_silent
if /i "%arg%"=="bg" goto run_silent
if /i "%arg%"=="2" goto run_silent
if /i "%arg%"=="status" goto check_status
if /i "%arg%"=="3" goto check_status
if /i "%arg%"=="logs" goto view_logs
if /i "%arg%"=="log" goto view_logs
if /i "%arg%"=="4" goto view_logs
if /i "%arg%"=="enable" goto enable_startup
if /i "%arg%"=="enable-startup" goto enable_startup
if /i "%arg%"=="5" goto enable_startup
if /i "%arg%"=="disable" goto disable_startup
if /i "%arg%"=="disable-startup" goto disable_startup
if /i "%arg%"=="6" goto disable_startup
if /i "%arg%"=="stop" goto stop_watcher
if /i "%arg%"=="7" goto stop_watcher
echo Unknown argument: %arg%
echo Usage: PhotoRelay-Windows.bat [watch^|silent^|status^|logs^|enable^|disable^|stop]
exit /b 1

:run_watcher
if "%IS_MENU%"=="1" cls
%PS_CMD% -File "%~dp0WatchAndUpload.ps1"
if "%IS_MENU%"=="1" (pause & goto menu)
exit /b %ERRORLEVEL%

:run_silent
if "%IS_MENU%"=="1" cls
echo Launching PhotoRelay-Windows watcher in silent background mode...
wscript.exe "%~dp0StartPhotosWatcher.vbs"
echo [OK] Background watcher launched.
if "%IS_MENU%"=="1" (timeout /t 3 >nul & goto menu)
exit /b 0

:check_status
if "%IS_MENU%"=="1" cls
%PS_CMD% -File "%~dp0WatchAndUpload.ps1" -StatusOnly
if "%IS_MENU%"=="1" (pause & goto menu)
exit /b %ERRORLEVEL%

:view_logs
if "%IS_MENU%"=="1" cls
%PS_CMD% -File "%~dp0WatchAndUpload.ps1" -ShowLogs
if "%IS_MENU%"=="1" (pause & goto menu)
exit /b %ERRORLEVEL%

:enable_startup
if "%IS_MENU%"=="1" cls
%PS_CMD% -File "%~dp0WatchAndUpload.ps1" -EnableStartup
if "%IS_MENU%"=="1" (pause & goto menu)
exit /b %ERRORLEVEL%

:disable_startup
if "%IS_MENU%"=="1" cls
%PS_CMD% -File "%~dp0WatchAndUpload.ps1" -DisableStartup
if "%IS_MENU%"=="1" (pause & goto menu)
exit /b %ERRORLEVEL%

:stop_watcher
if "%IS_MENU%"=="1" cls
%PS_CMD% -File "%~dp0WatchAndUpload.ps1" -StopWatcher
if "%IS_MENU%"=="1" (pause & goto menu)
exit /b %ERRORLEVEL%
