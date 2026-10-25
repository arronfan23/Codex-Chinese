@echo off
setlocal
if exist "%~dp0install.ps1" (
  set "PS1=%~dp0install.ps1"
) else (
  set "PS1=%~dp0src\install.ps1"
)
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
if errorlevel 1 (
  echo.
  echo [INSTALL FAILED] See error messages above.
  pause
)
