@echo off
setlocal
if exist "%~dp0install.ps1" (
  set "PS1=%~dp0install.ps1"
) else (
  set "PS1=%~dp0src\install.ps1"
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
if errorlevel 1 (
  echo.
  echo [INSTALL FAILED] See error messages above.
  pause
)
