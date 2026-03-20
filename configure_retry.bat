@echo off
REM ============================================================
REM  configure_retry.bat
REM  Retries cmake configure until all FetchContent downloads
REM  succeed. Does NOT delete build_clean between retries so
REM  already-downloaded packages are reused.
REM ============================================================

call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 ( echo ERROR: VS not found & pause & exit /b 1 )

set "QTBIN=E:\Qt\6.8.3\msvc2022_64\bin"
set "PATH=%QTBIN%;%PATH%"

subst Z: /D >nul 2>&1
subst Z: "E:\qgc-pxlabs"
if errorlevel 1 ( echo ERROR: subst failed & pause & exit /b 1 )

set "SRC_DIR=Z:"
set "BUILD_DIR=Z:\build_clean"

set ATTEMPT=0

:RETRY
set /a ATTEMPT+=1
echo.
echo ============================================================
echo  Configure attempt %ATTEMPT%
echo ============================================================

cmake -S "%SRC_DIR%" -B "%BUILD_DIR%" -G "Visual Studio 17 2022" -A x64 ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DQt6_DIR="E:/Qt/6.8.3/msvc2022_64/lib/cmake/Qt6" ^
    -DQGC_APP_NAME="G-Control"

if errorlevel 1 (
    echo.
    echo Configure failed on attempt %ATTEMPT% — retrying...
    REM Delete CMakeCache so cmake re-runs configure fully
    REM but keep _deps folder so already-downloaded packages survive
    del /Q "%BUILD_DIR%\CMakeCache.txt" >nul 2>&1
    del /Q "%BUILD_DIR%\CMakeFiles\cmake.check_cache" >nul 2>&1
    if %ATTEMPT% LSS 10 goto RETRY
    echo ERROR: configure failed after 10 attempts.
    subst Z: /D >nul 2>&1
    pause
    exit /b 1
)

echo.
echo ============================================================
echo  Configure SUCCEEDED on attempt %ATTEMPT%
echo  Now building...
echo ============================================================

cmake --build "%BUILD_DIR%" --config Release --target G-Control -- /m:4
if errorlevel 1 (
    echo BUILD FAILED.
    subst Z: /D >nul 2>&1
    pause
    exit /b 1
)

REM Copy tools
if not exist "%BUILD_DIR%\Release\tools" mkdir "%BUILD_DIR%\Release\tools"
copy /Y "%SRC_DIR%\tools\pxlabs_cli.py" "%BUILD_DIR%\Release\tools\pxlabs_cli.py" >nul

subst Z: /D >nul 2>&1

echo.
echo ============================================================
echo  BUILD SUCCEEDED
echo  EXE: E:\qgc-pxlabs\build_clean\Release\G-Control.exe
echo ============================================================
pause
