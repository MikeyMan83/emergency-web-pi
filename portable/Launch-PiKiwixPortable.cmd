@echo off
setlocal
set SCRIPT_DIR=%~dp0
pushd "%SCRIPT_DIR%" >nul 2>&1

if not exist "%SCRIPT_DIR%PiKiwixPortable.ps1" (
	echo PiKiwixPortable.ps1 is missing from this folder.
	echo Extract the complete release ZIP and retry.
	powershell -NoProfile -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('PiKiwixPortable.ps1 is missing. Extract the full release ZIP and retry.','Pi Kiwix Portable')"
	popd >nul 2>&1
	exit /b 1
)

if exist "%SCRIPT_DIR%PiKiwixPortable.exe" (
	start "" /D "%SCRIPT_DIR%" "%SCRIPT_DIR%PiKiwixPortable.exe"
	set ERR=%ERRORLEVEL%
	popd >nul 2>&1
	exit /b %ERR%
) else (
	powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_DIR%PiKiwixPortable.ps1"
	set ERR=%ERRORLEVEL%
	popd >nul 2>&1
	exit /b %ERR%
)
