@echo off
setlocal
cd /d "%~dp0"

echo ============================================================
echo  Gen1Recomp Grass OBJ Replacer - One Click Publisher
echo ============================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\publish_update.ps1"
set ERR=%ERRORLEVEL%

echo.
if not "%ERR%"=="0" (
  echo Publish failed. Read the error above.
  pause
  exit /b %ERR%
)

echo Publish command finished successfully.
echo GitHub Actions will build the release automatically.
echo.
pause
exit /b 0
