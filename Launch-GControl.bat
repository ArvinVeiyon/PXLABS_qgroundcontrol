@echo off
REM ============================================================
REM  Launch G-Control.exe with GStreamer environment
REM ============================================================

set "RELEASE_DIR=E:\qgc-pxlabs\build_clean\Release"
set "GST_ROOT=E:\gstreamer\1.0\msvc_x86_64"

set "GSTREAMER_1_0_ROOT_MSVC_X86_64=%GST_ROOT%"
set "GST_PLUGIN_PATH=%GST_ROOT%\lib\gstreamer-1.0"
set "GST_REGISTRY_REUSE_PLUGIN_SCANNER=no"
set "PATH=%GST_ROOT%\bin;%RELEASE_DIR%;%PATH%"

REM --- Qt logging: enable all video manager categories ---
set "QT_LOGGING_RULES=qgc.videomanager.*=true"

echo Launching G-Control...
start "" "%RELEASE_DIR%\G-Control.exe"
