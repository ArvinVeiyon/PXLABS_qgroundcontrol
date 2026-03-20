@echo off
REM ============================================================
REM  PXLABS G-Control — Deploy DLLs
REM
REM  Smart deploy:
REM   - GStreamer DLLs: robocopy skips unchanged files (fast)
REM   - windeployqt   : only runs if Qt6Core.dll is missing
REM                     (first deploy, or after clean build)
REM  Pass --force to force windeployqt even if DLLs exist.
REM ============================================================

echo ============================================================
echo   PXLABS G-Control — Deploy DLLs
echo ============================================================

set "RELEASE_DIR=E:\qgc-pxlabs\build_clean\Release"
set "BUILD_DIR=E:\qgc-pxlabs\build_clean"
set "GSTREAMER_ROOT=E:\gstreamer\1.0\msvc_x86_64"
set "GSTREAMER_BIN=%GSTREAMER_ROOT%\bin"
set "GSTREAMER_PLUGINS=%GSTREAMER_ROOT%\lib\gstreamer-1.0"
set "GSTREAMER_GIO=%GSTREAMER_ROOT%\lib\gio"
set "GSTREAMER_LIBEXEC=%GSTREAMER_ROOT%\libexec\gstreamer-1.0"
set "QTBIN=E:\Qt\6.8.3\msvc2022_64\bin"

REM --- Map Z: for windeployqt qmldir scan ---
subst Z: /D >nul 2>&1
subst Z: "E:\qgc-pxlabs"
if errorlevel 1 (
    echo ERROR: Could not map Z: drive.
    pause
    exit /b 1
)

REM --- GStreamer DLLs ---
echo.
echo Deploying GStreamer DLLs...
robocopy "%GSTREAMER_BIN%" "%RELEASE_DIR%" "*.dll" /NJH /NJS

echo.
echo Deploying GStreamer plugins to Release\gstreamer-plugins (legacy)...
if not exist "%RELEASE_DIR%\gstreamer-plugins" mkdir "%RELEASE_DIR%\gstreamer-plugins"
robocopy "%GSTREAMER_PLUGINS%" "%RELEASE_DIR%\gstreamer-plugins" "*.dll" /NJH /NJS

REM --- GStreamer lib structure (required by GStreamer.cc internal path logic) ---
REM   GStreamer.cc on Windows looks for <appDir>/../lib/gstreamer-1.0
REM   appDir = build_clean\Release, so it expects build_clean\lib\gstreamer-1.0
echo.
echo Deploying GStreamer lib structure for internal path resolution...
if not exist "%BUILD_DIR%\lib\gstreamer-1.0" mkdir "%BUILD_DIR%\lib\gstreamer-1.0"
robocopy "%GSTREAMER_PLUGINS%" "%BUILD_DIR%\lib\gstreamer-1.0" "*.dll" /NJH /NJS

REM --- GStreamer gio modules (for GST_REGISTRY_REUSE_PLUGIN_SCANNER and codec support) ---
if exist "%GSTREAMER_GIO%" (
    if not exist "%BUILD_DIR%\lib\gio\modules" mkdir "%BUILD_DIR%\lib\gio\modules"
    robocopy "%GSTREAMER_GIO%\modules" "%BUILD_DIR%\lib\gio\modules" "*.dll" /NJH /NJS
)

REM --- GStreamer libexec (plugin scanner) ---
if exist "%GSTREAMER_LIBEXEC%" (
    if not exist "%BUILD_DIR%\libexec\gstreamer-1.0" mkdir "%BUILD_DIR%\libexec\gstreamer-1.0"
    robocopy "%GSTREAMER_LIBEXEC%" "%BUILD_DIR%\libexec\gstreamer-1.0" "*.exe" /NJH /NJS
)

REM --- windeployqt — only if Qt6Core.dll missing OR --force passed ---
set FORCE_WINDEPLOYQT=0
if "%1"=="--force" set FORCE_WINDEPLOYQT=1
if "%1"=="/force" set FORCE_WINDEPLOYQT=1

echo.
if exist "%RELEASE_DIR%\Qt6Core.dll" (
    if "%FORCE_WINDEPLOYQT%"=="0" (
        echo Skipping windeployqt  ^(Qt DLLs already present — pass --force to re-run^)
        goto :skip_windeployqt
    )
)
echo Running windeployqt...
"%QTBIN%\windeployqt.exe" --release --qmldir "Z:\src" "Z:\build_clean\Release\G-Control.exe"
:skip_windeployqt

REM --- tools folder ---
echo.
echo Ensuring tools folder...
if not exist "%RELEASE_DIR%\tools" mkdir "%RELEASE_DIR%\tools"
copy /Y "Z:\tools\pxlabs_cli.py" "%RELEASE_DIR%\tools\pxlabs_cli.py" >nul
echo   pxlabs_cli.py deployed.

subst Z: /D >nul 2>&1

echo.
echo ============================================================
echo   Deploy complete. Launch via Launch-GControl.bat
echo ============================================================
pause
