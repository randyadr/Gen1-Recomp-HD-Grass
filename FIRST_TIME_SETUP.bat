@echo off
setlocal
cd /d "%~dp0"

echo ============================================================
echo  Grass OBJ Replacer - FIRST TIME GITHUB SETUP
echo ============================================================
echo.
echo This will create/link the public GitHub repo, push the source,
echo create the current GitHub Release, and verify Gen1Recomp's
 echo update URL.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\first_time_setup.ps1"
set ERR=%ERRORLEVEL%

echo.
if not "%ERR%"=="0" (
  echo Setup FAILED. Read the message above.
  pause
  exit /b %ERR%
)

echo Setup finished successfully.
pause
exit /b 0
