@echo off
setlocal
if exist "%~dp0launch.ps1" (
  set "PS1=%~dp0launch.ps1"
) else (
  set "PS1=%~dp0src\launch.ps1"
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
if errorlevel 1 (
  echo.
  echo [启动失败，请查看上方错误信息]
  pause
)
