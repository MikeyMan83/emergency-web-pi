@echo off
setlocal
set ROOT_DIR=%~dp0
pushd "%ROOT_DIR%" >nul 2>&1

if exist "%ROOT_DIR%PiKiwixPortable.exe" (
	start "" /D "%ROOT_DIR%" "%ROOT_DIR%PiKiwixPortable.exe"
	set ERR=%ERRORLEVEL%
	popd >nul 2>&1
	exit /b %ERR%
)

if exist "%ROOT_DIR%portable\PiKiwixPortable.exe" (
	start "" /D "%ROOT_DIR%portable" "%ROOT_DIR%portable\PiKiwixPortable.exe"
	set ERR=%ERRORLEVEL%
	popd >nul 2>&1
	exit /b %ERR%
)

if not exist "%ROOT_DIR%portable\Launch-PiKiwixPortable.cmd" (
	echo The portable app files were not found next to this launcher.
	echo Extract the full release ZIP first, then run this launcher again.
	powershell -NoProfile -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('Extract the full release ZIP first, then run PiKiwixPortable.exe or Launch-PiKiwixPortable.cmd from the extracted folder.','Pi Kiwix Portable')"
	popd >nul 2>&1
	exit /b 1
)

start "" /D "%ROOT_DIR%portable" "%ROOT_DIR%portable\Launch-PiKiwixPortable.cmd"
set ERR=%ERRORLEVEL%
popd >nul 2>&1
exit /b %ERR%
