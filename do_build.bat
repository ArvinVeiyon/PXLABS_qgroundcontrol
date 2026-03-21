@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
set "PATH=E:\Qt\6.8.3\msvc2022_64\bin;%PATH%"
subst Z: /D >nul 2>&1
subst Z: "E:\qgc-pxlabs"
echo Running cmake build...
cmake --build Z:\build_clean --config Release --target G-Control -- /m:4
if errorlevel 1 (
    echo BUILD FAILED
    subst Z: /D >nul 2>&1
    exit /b 1
)
subst Z: /D >nul 2>&1
echo BUILD OK - running deploy...
call "E:\qgc-pxlabs\deploy_dlls.bat"
echo DONE
