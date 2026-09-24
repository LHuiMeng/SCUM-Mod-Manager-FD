@echo off
REM ============================================================================
REM SCUM Mod Manager v2.6.5 - One-click build script (source package)
REM Double-click this file to build the installer .exe and portable .zip
REM from source. Requires: Flutter SDK + NSIS (see README.txt).
REM ASCII-only comments. Uses goto labels (no paren blocks) so that calling
REM flutter.bat (which itself contains paren blocks) never breaks parsing.
REM ============================================================================

setlocal
cd /d "%~dp0"

echo.
echo ============================================
echo  SCUM Mod Manager v2.6.5 - Build from source
echo ============================================
echo.

REM --- 1. Locate flutter (PATH -> FLUTTER_BAT env -> common install dirs) ---
set "FLUTTER="
where flutter >nul 2>&1 && set "FLUTTER=flutter"
if defined FLUTTER goto flutter_found
if defined FLUTTER_BAT if exist "%FLUTTER_BAT%" set "FLUTTER=%FLUTTER_BAT%"
if defined FLUTTER goto flutter_found
if exist "%USERPROFILE%\flutter\bin\flutter.bat" set "FLUTTER=%USERPROFILE%\flutter\bin\flutter.bat"
if defined FLUTTER goto flutter_found
if exist "C:\src\flutter\bin\flutter.bat" set "FLUTTER=C:\src\flutter\bin\flutter.bat"
if defined FLUTTER goto flutter_found
if exist "C:\flutter\bin\flutter.bat" set "FLUTTER=C:\flutter\bin\flutter.bat"
if defined FLUTTER goto flutter_found
if exist "D:\flutter\bin\flutter.bat" set "FLUTTER=D:\flutter\bin\flutter.bat"
if defined FLUTTER goto flutter_found
if exist "%LOCALAPPDATA%\flutter\bin\flutter.bat" set "FLUTTER=%LOCALAPPDATA%\flutter\bin\flutter.bat"
if defined FLUTTER goto flutter_found
echo.
echo [ERROR] Flutter SDK not found.
echo   Install Flutter: https://flutter.dev
echo   then make sure `flutter` is in PATH, OR set the FLUTTER_BAT
echo   environment variable to the full path of flutter.bat.
echo.
echo   Example:
echo     set FLUTTER_BAT=C:\path\to\flutter\bin\flutter.bat
echo     build.bat
echo.
pause
exit /b 1

:flutter_found
echo   Flutter: %FLUTTER%

REM --- 2. pub get ---
echo.
echo   Running: flutter pub get ...
call "%FLUTTER%" pub get
if errorlevel 1 goto pubget_failed

REM --- 3. Build release (NO cloud defines = standalone/local edition) ---
echo.
echo   Running: flutter build windows --release ...
call "%FLUTTER%" build windows --release --dart-define=APP_VERSION=2.6.5
if errorlevel 1 goto build_failed

set "RELEASE=%~dp0build\windows\x64\runner\Release"
if not exist "%RELEASE%\scum_mod_manager_app.exe" goto release_missing

REM --- 4. Prepare dist ---
if not exist "%~dp0build\dist" mkdir "%~dp0build\dist"

REM --- 5. Build NSIS installer (if makensis available) ---
set "NSIS="
where makensis >nul 2>&1 && set "NSIS=makensis"
if defined NSIS goto nsis_ready
if exist "%ProgramFiles(x86)%\NSIS\makensis.exe" set "NSIS=%ProgramFiles(x86)%\NSIS\makensis.exe"
if defined NSIS goto nsis_ready
if exist "%ProgramFiles%\NSIS\makensis.exe" set "NSIS=%ProgramFiles%\NSIS\makensis.exe"
if defined NSIS goto nsis_ready
echo.
echo   [SKIP] NSIS not found - skipping installer. Portable will still be built.
echo   Install NSIS: https://nsis.sourceforge.io
goto portable

:nsis_ready
echo.
echo   Building NSIS installer ...
pushd "%~dp0installer"
call "%NSIS%" /DPUBLIC_BUILD installer.nsi
popd
if errorlevel 1 echo   [WARN] NSIS build failed (continuing with portable only).

:portable
REM --- 6. Build portable (v3 install-root layout) ---
echo.
echo   Building portable edition ...
set "PORT=%~dp0build\dist\scum_mod_manager_v2.6.5_public_portable"
if exist "%PORT%" rmdir /s /q "%PORT%"
mkdir "%PORT%"
mkdir "%PORT%\versions\2.6.5"
copy /y "%RELEASE%\scum_mod_manager.exe" "%PORT%\" >nul
echo {"current":"2.6.5"} > "%PORT%\app.json"
copy /y "%RELEASE%\scum_mod_manager_app.exe" "%PORT%\versions\2.6.5\" >nul
copy /y "%RELEASE%\flutter_windows.dll" "%PORT%\versions\2.6.5\" >nul
xcopy /e /i /y /q "%RELEASE%\data" "%PORT%\versions\2.6.5\data\" >nul

echo.
echo ============================================
echo  Done! Outputs:
echo   Installer : build\dist\scum_mod_manager_v2.6.5_public_setup.exe  (if NSIS present)
echo   Portable  : build\dist\scum_mod_manager_v2.6.5_public_portable\
echo ============================================
echo.
pause
exit /b 0

:pubget_failed
echo.
echo [ERROR] flutter pub get failed.
pause
exit /b 1

:build_failed
echo.
echo [ERROR] flutter build failed.
pause
exit /b 1

:release_missing
echo.
echo [ERROR] Build output not found: %RELEASE%
pause
exit /b 1
