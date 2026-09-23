@echo off
setlocal
set SCRIPT_DIR=%~dp0
pushd "%SCRIPT_DIR%" >nul 2>&1
set "LOG_DIR=%LOCALAPPDATA%\EmergencyWebPi"
set "LOG_FILE=%LOG_DIR%\launcher.log"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
echo [%DATE% %TIME%] CMD launcher started from "%SCRIPT_DIR%" >> "%LOG_FILE%"

if not exist "%SCRIPT_DIR%EmergencyWebPi.ps1" (
	echo [%DATE% %TIME%] ERROR: EmergencyWebPi.ps1 is missing. >> "%LOG_FILE%"
	echo EmergencyWebPi.ps1 is missing from this folder.
	echo Extract the complete release ZIP and retry.
	powershell -NoProfile -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('EmergencyWebPi.ps1 is missing. Extract the full release ZIP and retry.','Emergency Web Pi')"
	popd >nul 2>&1
	exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_DIR%EmergencyWebPi.ps1" >> "%LOG_FILE%" 2>&1
set ERR=%ERRORLEVEL%
echo [%DATE% %TIME%] Frontend process exited with code %ERR%. >> "%LOG_FILE%"
popd >nul 2>&1
exit /b %ERR%
