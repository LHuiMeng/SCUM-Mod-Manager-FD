@echo off
REM ============================================================================
REM SCUM Mod Manager - Build Installer + Portable Edition
REM Usage: build_installer.bat
REM ============================================================================

setlocal enabledelayedexpansion

set PROJECT_DIR=%~dp0..
set FLUTTER_BAT=W:\hermes\flutter\flutter\bin\flutter.bat
set NSIS_EXE=C:\Program Files (x86)\NSIS\makensis.exe
set VERSION=2.6.5

echo.
echo === [1/4] Flutter build (release, with update verify key) ===
echo.
cd /d "%PROJECT_DIR%"
if not exist "%PROJECT_DIR%\update_secret.json" (
    echo ERROR: update_secret.json missing - 更新验签密钥（内部版发布必需）
    echo        请联系项目维护者获取，或使用 build_public.bat 构建对外版
    exit /b 1
)
call "%FLUTTER_BAT%" build windows --release --dart-define-from-file=update_secret.json --dart-define=APP_VERSION=%VERSION%
if errorlevel 1 (
    echo ERROR: flutter build failed
    exit /b 1
)

echo.
echo === [2/4] Prepare dist directory ===
echo.
if not exist "%PROJECT_DIR%\build\dist" mkdir "%PROJECT_DIR%\build\dist"

echo.
echo === [3/4] Build NSIS installer ===
echo.
cd /d "%PROJECT_DIR%\installer"
"%NSIS_EXE%" installer.nsi
if errorlevel 1 (
    echo ERROR: NSIS build failed
    exit /b 1
)

echo.
echo === [4/4] Build portable edition ===
echo.
set PORTABLE_DIR=%PROJECT_DIR%\build\dist\scum_mod_manager_v%VERSION%_portable
if exist "%PORTABLE_DIR%" rmdir /s /q "%PORTABLE_DIR%"
mkdir "%PORTABLE_DIR%"
xcopy /e /i /y /q "%PROJECT_DIR%\build\windows\x64\runner\Release\*" "%PORTABLE_DIR%\"
echo Portable edition built at: %PORTABLE_DIR%

echo.
echo === Done ===
echo.
echo Installer : %PROJECT_DIR%\build\dist\scum_mod_manager_v%VERSION%_setup.exe
echo Portable  : %PORTABLE_DIR%\scum_mod_manager.exe
echo.
