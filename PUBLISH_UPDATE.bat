@echo off
setlocal
cd /d "%~dp0"

echo ============================================================
echo  Grass OBJ Replacer - PUBLISH UPDATE
echo ============================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\publish_update.ps1"
set ERR=%ERRORLEVEL%

echo.
if not "%ERR%"=="0" (
  echo Publish FAILED. Read the message above.
  pause
  exit /b %ERR%
)

echo Publish finished successfully.
pause
exit /b 0
