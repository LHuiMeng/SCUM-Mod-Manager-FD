@echo off
REM ============================================================================
REM SCUM Mod Manager - Build PUBLIC (No-Cloud) Installer + Portable Edition
REM Usage: build_public.bat
REM
REM Public build: NO cloud registry / update manifest injected.
REM   - Cloud mods panel kept but shows empty list (user may configure
REM     cloud_sources.base_url in config.json)
REM   - Online update chain silently skipped (no update source)
REM   - Remote server SFTP panel kept (user fills address themselves)
REM ASCII-only comments: cmd.exe parses this file in GBK codepage.
REM ============================================================================

setlocal enabledelayedexpansion

set PROJECT_DIR=%~dp0
set FLUTTER_BAT=W:\hermes\flutter\flutter\bin\flutter.bat
set NSIS_EXE=C:\Program Files (x86)\NSIS\makensis.exe
set VERSION=2.6.5

echo.
echo === [1/4] Flutter build (release, NO cloud defines) ===
echo.
cd /d "%PROJECT_DIR%"
call "%FLUTTER_BAT%" build windows --release --dart-define=APP_VERSION=%VERSION%
if errorlevel 1 (
    echo ERROR: flutter build failed
    exit /b 1
)

echo.
echo === [2/4] Prepare dist directory ===
echo.
if not exist "%PROJECT_DIR%\build\dist" mkdir "%PROJECT_DIR%\build\dist"

echo.
echo === [3/4] Build NSIS installer (public) ===
echo.
cd /d "%PROJECT_DIR%\installer"
"%NSIS_EXE%" /DPUBLIC_BUILD installer.nsi
if errorlevel 1 (
    echo ERROR: NSIS build failed
    exit /b 1
)

echo.
echo === [4/4] Build portable edition (v3 install-root layout) ===
echo.
set PORTABLE_DIR=%PROJECT_DIR%\build\dist\scum_mod_manager_v%VERSION%_public_portable
if exist "%PORTABLE_DIR%" rmdir /s /q "%PORTABLE_DIR%"
mkdir "%PORTABLE_DIR%"

REM v3 architecture: install root = launcher + app.json + versions/<ver>/ app body.
REM Launcher reads app.json current -> starts versions/<ver>/scum_mod_manager_app.exe.
REM User data (~mods/ue4ss_runtime/config.json etc.) stays at top level.
set VER_DIR=%PORTABLE_DIR%\versions\%VERSION%
mkdir "%VER_DIR%"

REM 1) Install root: launcher + app.json (the only switch pointer)
copy /y "%PROJECT_DIR%\build\windows\x64\runner\Release\scum_mod_manager.exe" "%PORTABLE_DIR%\"
echo {"current":"%VERSION%"} > "%PORTABLE_DIR%\app.json"

REM 2) versions/<ver>/ app body (app exe + DLL + data/, no user data)
copy /y "%PROJECT_DIR%\build\windows\x64\runner\Release\scum_mod_manager_app.exe" "%VER_DIR%\"
copy /y "%PROJECT_DIR%\build\windows\x64\runner\Release\flutter_windows.dll" "%VER_DIR%\"
xcopy /e /i /y /q "%PROJECT_DIR%\build\windows\x64\runner\Release\data" "%VER_DIR%\data\"
echo Portable edition built at: %PORTABLE_DIR%
echo.

echo.
echo === Done ===
echo.
echo Installer : %PROJECT_DIR%\build\dist\scum_mod_manager_v%VERSION%_public_setup.exe
echo Portable  : %PORTABLE_DIR%\scum_mod_manager.exe
echo.
