@echo off
:: Universal Rclone Mount Manager - 1-Click Installer (Windows)
:: Automatically elevates to Administrator, installs dependencies (rclone, WinFsp),
:: configures background tasks, and starts the mount.

setlocal

echo Requesting Administrative Privileges...
net session >nul 2>&1
if %errorLevel% == 0 (
    echo Success: Administrative privileges confirmed.
) else (
    echo Failure: Current permissions inadequate. Re-launching with elevation...
    powershell -Command "Start-Process '%~0' -Verb RunAs"
    exit /b
)

echo.
echo =======================================================
echo     Installing Universal Rclone Mount Manager
echo =======================================================
echo.

:: Execute the installer script (which handles dependency checking and task scheduling)
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Mount-GDrive.ps1" -Action Install -Watchdog

echo.
echo =======================================================
echo Installation Complete!
echo Your cloud drive will now mount automatically at logon.
echo You may close this window.
echo =======================================================
pause
