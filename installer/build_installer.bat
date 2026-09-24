@echo off
REM ============================================================================
REM SCUM Mod Manager - Build Installer + Portable Edition (internal build)
REM Usage: build_installer.bat
REM Requires: Flutter SDK (PATH or FLUTTER_BAT), NSIS (optional), and
REM           update_secret.json for the update verify key (internal releases).
REM For the standalone (no-cloud) build use build_public.bat instead.
REM ASCII-only comments: cmd.exe parses this file in GBK codepage.
REM ============================================================================

setlocal enabledelayedexpansion

set PROJECT_DIR=%~dp0..
set VERSION=2.6.5

REM --- Locate flutter ---
set "FLUTTER="
where flutter >nul 2>&1 && set "FLUTTER=flutter"
if not defined FLUTTER (
    if defined FLUTTER_BAT (
        if exist "%FLUTTER_BAT%" set "FLUTTER=%FLUTTER_BAT%"
    )
)
if not defined FLUTTER (
    echo [ERROR] Flutter SDK not found. Install from https://flutter.dev
    echo   and add to PATH, or set FLUTTER_BAT.
    pause
    exit /b 1
)
echo   Flutter: %FLUTTER%

echo.
echo === [1/4] Flutter build (release, with update verify key) ===
echo.
cd /d "%PROJECT_DIR%"
if not exist "%PROJECT_DIR%\update_secret.json" (
    echo ERROR: update_secret.json missing - update verify key (internal releases only).
    echo         Ask the maintainer for it, or use build_public.bat for the no-cloud build.
    pause
    exit /b 1
)
call "%FLUTTER%" build windows --release --dart-define-from-file=update_secret.json --dart-define=APP_VERSION=%VERSION%
if errorlevel 1 (
    echo ERROR: flutter build failed
    pause
    exit /b 1
)

echo.
echo === [2/4] Prepare dist directory ===
echo.
if not exist "%PROJECT_DIR%\build\dist" mkdir "%PROJECT_DIR%\build\dist"

echo.
echo === [3/4] Build NSIS installer ===
echo.
set "NSIS="
where makensis >nul 2>&1 && set "NSIS=makensis"
if not defined NSIS (
    if exist "C:\Program Files (x86)\NSIS\makensis.exe" set "NSIS=C:\Program Files (x86)\NSIS\makensis.exe"
)
if defined NSIS (
    cd /d "%PROJECT_DIR%\installer"
    call "%NSIS%" installer.nsi
    if errorlevel 1 (
        echo [WARN] NSIS build failed (continuing with portable only).
    )
) else (
    echo [SKIP] NSIS not found - skipping installer. Install from https://nsis.sourceforge.io
)

echo.
echo === [4/4] Build portable edition (v3 install-root layout) ===
echo.
set PORTABLE_DIR=%PROJECT_DIR%\build\dist\scum_mod_manager_v%VERSION%_portable
if exist "%PORTABLE_DIR%" rmdir /s /q "%PORTABLE_DIR%"
mkdir "%PORTABLE_DIR%"
set VER_DIR=%PORTABLE_DIR%\versions\%VERSION%
mkdir "%VER_DIR%"
copy /y "%PROJECT_DIR%\build\windows\x64\runner\Release\scum_mod_manager.exe" "%PORTABLE_DIR%\"
echo {"current":"%VERSION%"} > "%PORTABLE_DIR%\app.json"
copy /y "%PROJECT_DIR%\build\windows\x64\runner\Release\scum_mod_manager_app.exe" "%VER_DIR%\"
copy /y "%PROJECT_DIR%\build\windows\x64\runner\Release\flutter_windows.dll" "%VER_DIR%\"
xcopy /e /i /y /q "%PROJECT_DIR%\build\windows\x64\runner\Release\data" "%VER_DIR%\data\"
echo Portable edition built at: %PORTABLE_DIR%

echo.
echo === Done ===
echo.
echo Installer : %PROJECT_DIR%\build\dist\scum_mod_manager_v%VERSION%_setup.exe
echo Portable  : %PORTABLE_DIR%\scum_mod_manager.exe
echo.
pause
