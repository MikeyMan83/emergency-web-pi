@echo off
setlocal
set SCRIPT_DIR=%~dp0
if exist "%SCRIPT_DIR%PiKiwixPortable.exe" (
	"%SCRIPT_DIR%PiKiwixPortable.exe"
) else (
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%PiKiwixPortable.ps1"
)
