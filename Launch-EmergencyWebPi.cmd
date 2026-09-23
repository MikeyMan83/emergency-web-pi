@echo off
setlocal
set ROOT_DIR=%~dp0
pushd "%ROOT_DIR%" >nul 2>&1
set "LOG_DIR=%LOCALAPPDATA%\EmergencyWebPi"
set "LOG_FILE=%LOG_DIR%\launcher.log"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
echo [%DATE% %TIME%] Root CMD launcher started from "%ROOT_DIR%" >> "%LOG_FILE%"

if not exist "%ROOT_DIR%portable\EmergencyWebPi.ps1" (
	echo [%DATE% %TIME%] ERROR: Portable frontend script is missing. >> "%LOG_FILE%"
	echo The portable app files were not found next to this launcher.
	echo Extract the full release ZIP first, then run this launcher again.
	powershell -NoProfile -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('Extract the full release ZIP first, then run EmergencyWebPi.exe or Launch-EmergencyWebPi.cmd from the extracted folder.','Emergency Web Pi')"
	popd >nul 2>&1
	exit /b 1
)

powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%ROOT_DIR%portable\EmergencyWebPi.ps1" >> "%LOG_FILE%" 2>&1
set ERR=%ERRORLEVEL%
echo [%DATE% %TIME%] Frontend process exited with code %ERR%. >> "%LOG_FILE%"
if not "%ERR%"=="0" (
	echo Emergency Web Pi did not start. Diagnostic log: "%LOG_FILE%"
	pause
)
popd >nul 2>&1
exit /b %ERR%
