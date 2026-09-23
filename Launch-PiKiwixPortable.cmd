@echo off
setlocal
set ROOT_DIR=%~dp0

if not exist "%ROOT_DIR%portable\Launch-PiKiwixPortable.cmd" (
	echo The portable app files were not found next to this launcher.
	echo Extract the full release ZIP first, then run this launcher again.
	powershell -NoProfile -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('Extract the full release ZIP first, then run PiKiwixPortable.exe or Launch-PiKiwixPortable.cmd from the extracted folder.','Pi Kiwix Portable')"
	exit /b 1
)

start "" "%ROOT_DIR%portable\Launch-PiKiwixPortable.cmd"
