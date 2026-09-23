@echo off
setlocal
set SCRIPT_DIR=%~dp0
if exist "%SCRIPT_DIR%PiKiwixPortable.exe" (
	start "" "%SCRIPT_DIR%PiKiwixPortable.exe"
) else (
	start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_DIR%PiKiwixPortable.ps1"
)
