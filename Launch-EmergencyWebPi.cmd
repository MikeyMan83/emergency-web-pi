@echo off
setlocal
set ROOT_DIR=%~dp0
pushd "%ROOT_DIR%" >nul 2>&1

if not exist "%ROOT_DIR%portable\Launch-EmergencyWebPi.cmd" (
	echo The portable app files were not found next to this launcher.
	echo Extract the full release ZIP first, then run this launcher again.
	powershell -NoProfile -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('Extract the full release ZIP first, then run EmergencyWebPi.exe or Launch-EmergencyWebPi.cmd from the extracted folder.','Emergency Web Pi')"
	popd >nul 2>&1
	exit /b 1
)

call "%ROOT_DIR%portable\Launch-EmergencyWebPi.cmd"
set ERR=%ERRORLEVEL%
popd >nul 2>&1
exit /b %ERR%
