@echo off
setlocal
set SCRIPT_DIR=%~dp0
pushd "%SCRIPT_DIR%" >nul 2>&1

if not exist "%SCRIPT_DIR%EmergencyWebPi.ps1" (
	echo EmergencyWebPi.ps1 is missing from this folder.
	echo Extract the complete release ZIP and retry.
	powershell -NoProfile -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('EmergencyWebPi.ps1 is missing. Extract the full release ZIP and retry.','Emergency Web Pi')"
	popd >nul 2>&1
	exit /b 1
)

if exist "%SCRIPT_DIR%EmergencyWebPi.exe" (
	start "" /D "%SCRIPT_DIR%" "%SCRIPT_DIR%EmergencyWebPi.exe"
	set ERR=%ERRORLEVEL%
	popd >nul 2>&1
	exit /b %ERR%
) else (
	powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_DIR%EmergencyWebPi.ps1"
	set ERR=%ERRORLEVEL%
	popd >nul 2>&1
	exit /b %ERR%
)
