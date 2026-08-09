@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\first_time_setup.ps1"
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" (
  echo Setup FAILED. Read the message above.
  pause
  exit /b %ERR%
)
echo Setup complete. Run PUBLISH_UPDATE.bat when ready.
pause
