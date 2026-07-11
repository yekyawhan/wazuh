@echo off
REM uninstall.cmd — auto-elevate, run uninstaller. Pass --purge-logs to wipe logs.
setlocal
set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%uninstall\uninstall_usb_sync_windows.ps1"
set "ARGS=%*"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '%*'"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %ARGS%
exit /b %errorlevel%
