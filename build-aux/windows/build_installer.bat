@echo off
REM ──────────────────────────────────────────────────────────────────────
REM  QElectroTech Windows Installer Builder - Launcher
REM
REM  This wrapper invokes build_installer.ps1 with -ExecutionPolicy Bypass
REM  so that the script runs regardless of the system's PowerShell
REM  execution policy (which blocks unsigned scripts by default).
REM
REM  All arguments are forwarded to the PowerShell script.
REM  Usage:
REM      build_installer.bat
REM      build_installer.bat -QtDir "C:\Qt\5.15.2\msvc2019_64"
REM      build_installer.bat -SkipBuild
REM ──────────────────────────────────────────────────────────────────────

set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build_installer.ps1" %*
exit /b %ERRORLEVEL%
