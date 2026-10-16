@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0runtime\restart-widget.ps1"
if errorlevel 1 (
  echo Restart failed. See the error above.
  pause
  exit /b 1
)
