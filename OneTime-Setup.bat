@echo off
setlocal EnableExtensions
title PhotoRelay-Windows - One-Time Setup
cd /d "%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0PhotoRelay-Setup.ps1"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
  echo.
  echo Setup did not complete. Read the error above, then run this BAT again.
  pause
)
exit /b %RESULT%
