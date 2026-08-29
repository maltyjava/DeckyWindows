@echo off
rem ============================================================================
rem  Decky Loader - one-shot installer for Windows handhelds
rem
rem  Double-click this file. It will ask for administrator rights, install the
rem  toolchain, build Decky Loader from source, install it, and verify it.
rem
rem  Must sit in the same folder as bootstrap.ps1 and verify.ps1.
rem ============================================================================

title Decky Loader Installer
cd /d "%~dp0"

rem ---- elevate if needed -----------------------------------------------------
rem A double-clicked .bat is never elevated, and bootstrap.ps1 needs admin to
rem write the homebrew tree, the Steam CEF flag, and the scheduled task.
fltmc >nul 2>&1
if not errorlevel 1 goto :elevated

echo.
echo  Decky Loader Installer
echo  ----------------------
echo  Administrator rights are required. Please accept the UAC prompt.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
if errorlevel 1 (
    echo.
    echo  UAC was declined, so nothing was installed.
    echo  Right-click installer.bat and choose "Run as administrator" to retry.
    echo.
    pause
)
exit /b

:elevated
set "LOG=%~dp0install.log"
set "REF=%~1"

echo.
echo  ============================================================
echo   Decky Loader Installer
echo  ============================================================
echo   Folder : %~dp0
echo   Log    : %LOG%
if not "%REF%"=="" echo   Version: %REF%
echo.
echo   This installs Python 3.11, Node LTS and Git if missing, then
echo   builds Decky Loader from source. Expect roughly 10-20 minutes
echo   on a first run. Leave this window open.
echo.
echo  ============================================================
echo.

rem ---- sanity checks ---------------------------------------------------------
if not exist "%~dp0bootstrap.ps1" (
    echo  ERROR: bootstrap.ps1 not found next to this file.
    echo  Keep installer.bat in the DeckyWindows folder, alongside bootstrap.ps1.
    echo.
    pause
    exit /b 1
)

rem Files extracted from a downloaded ZIP carry the mark-of-the-web; clear it so
rem PowerShell does not balk at running them.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem '%~dp0*.ps1' | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

rem ---- install ---------------------------------------------------------------
echo  [1/2] Building and installing Decky Loader...
echo.
rem Tee-Object keeps the live progress visible while also writing the log, so a
rem failed run leaves something to read after the window is gone.
if "%REF%"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0bootstrap.ps1' *>&1 | Tee-Object -FilePath '%LOG%'"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0bootstrap.ps1' -Ref '%REF%' *>&1 | Tee-Object -FilePath '%LOG%'"
)
set "RC=%ERRORLEVEL%"

rem ---- verify ----------------------------------------------------------------
echo.
echo  [2/2] Verifying...
echo.
if exist "%~dp0verify.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0verify.ps1' *>&1 | Tee-Object -FilePath '%LOG%' -Append"
) else (
    echo  ^(verify.ps1 not found - skipping^)
)

rem ---- result ----------------------------------------------------------------
echo.
echo  ============================================================
if "%RC%"=="0" (
    echo   Install finished.
    echo.
    echo   Look for "port 1337: LISTENING" and "loaderPresent: true"
    echo   above. If you see both, Decky is running.
    echo.
    echo   Now fully exit Steam from the system tray - right-click
    echo   the tray icon and choose Exit, not just closing the
    echo   window - then start Steam again. Decky appears in the
    echo   Quick Access menu.
) else (
    echo   Install reported a problem ^(exit code %RC%^).
    echo.
    echo   Note the build can still have succeeded: git and PyInstaller
    echo   write to stderr, which shows up as a non-zero exit code.
    echo   Check the verify output above first.
    echo.
    echo   If port 1337 is not listening, run this for the traceback:
    echo     powershell -ExecutionPolicy Bypass -File verify.ps1 -Traceback
)
echo  ============================================================
echo.
pause
exit /b %RC%
