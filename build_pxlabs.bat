@echo off
REM ============================================================
REM  PXLABS G-Control Build Script
REM  Source : E:\qgc-pxlabs
REM  Build  : E:\qgc-pxlabs\build_clean
REM  Output : E:\qgc-pxlabs\build_clean\Release\G-Control.exe
REM
REM  Z: drive subst used to avoid CMake issues with spaces in
REM  paths (Qt/VS generator requirement).
REM ============================================================

echo ============================================================
echo   PXLABS G-Control Build  ^|  Branch: PXLABS-integration
echo ============================================================

REM --- VS 2022 Developer Environment ---
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 (
    echo ERROR: VS 2022 Community not found. Check path.
    pause
    exit /b 1
)

REM --- Qt to PATH ---
set "QTBIN=E:\Qt\6.8.3\msvc2022_64\bin"
set "PATH=%QTBIN%;%PATH%"

REM --- Map Z: to E:\qgc-pxlabs (space-free) ---
subst Z: /D >nul 2>&1
subst Z: "E:\qgc-pxlabs"
if errorlevel 1 (
    echo ERROR: Could not map Z: to E:\qgc-pxlabs
    pause
    exit /b 1
)

set "SRC_DIR=Z:"
set "BUILD_DIR=Z:\build_clean"

REM --- CMake Configure (only if no cache) ---
if not exist "%BUILD_DIR%\CMakeCache.txt" (
    echo.
    echo Configuring CMake...
    cmake -S "%SRC_DIR%" -B "%BUILD_DIR%" -G "Visual Studio 17 2022" -A x64 ^
        -DCMAKE_BUILD_TYPE=Release ^
        -DQt6_DIR="E:/Qt/6.8.3/msvc2022_64/lib/cmake/Qt6" ^
        -DQGC_APP_NAME="G-Control"
    if errorlevel 1 (
        echo ERROR: CMake configure failed.
        subst Z: /D >nul 2>&1
        pause
        exit /b 1
    )
)

REM --- Build ---
echo.
echo Building G-Control (Release)  — using /m:4 parallel jobs...
cmake --build "%BUILD_DIR%" --config Release --target G-Control -- /m:4
if errorlevel 1 (
    echo.
    echo BUILD FAILED. Check errors above.
    subst Z: /D >nul 2>&1
    pause
    exit /b 1
)

subst Z: /D >nul 2>&1

REM --- Auto-deploy DLLs + tools (smart: skips windeployqt if Qt DLLs exist) ---
echo.
echo Running deploy_dlls.bat...
call "E:\qgc-pxlabs\deploy_dlls.bat"

echo.
echo ============================================================
echo   BUILD + DEPLOY COMPLETE
echo   EXE : E:\qgc-pxlabs\build_clean\Release\G-Control.exe
echo   Launch via Launch-GControl.bat
echo ============================================================
pause
