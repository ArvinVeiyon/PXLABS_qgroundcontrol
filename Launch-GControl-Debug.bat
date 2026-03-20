@echo off
REM ============================================================
REM  Launch G-Control.exe — DEBUG MODE
REM  GStreamer logs written to: build_clean\Release\gst_debug.log
REM  GST_DEBUG levels: 1=ERROR 2=WARNING 3=FIXME 4=INFO 5=DEBUG
REM ============================================================

set "RELEASE_DIR=E:\qgc-pxlabs\build_clean\Release"
set "GST_ROOT=E:\gstreamer\1.0\msvc_x86_64"
set "LOG_FILE=%RELEASE_DIR%\gst_debug.log"

set "GSTREAMER_1_0_ROOT_MSVC_X86_64=%GST_ROOT%"
set "GST_PLUGIN_PATH=%GST_ROOT%\lib\gstreamer-1.0"
set "GST_REGISTRY_REUSE_PLUGIN_SCANNER=no"
set "PATH=%GST_ROOT%\bin;%RELEASE_DIR%;%PATH%"

REM --- GStreamer debug: use native logger (bypasses Qt log handler)
REM     Focus on video pipeline elements
set "GST_DEBUG=2,qml6*:5,qgc*:5,udpsrc:4,rtph264depay:4,h264parse:4,decodebin*:5,d3d11*:4,openh264*:4,videodecoder:4"
set "GST_DEBUG_FILE=%LOG_FILE%"
set "GST_DEBUG_NO_COLOR=1"

echo ============================================================
echo   G-Control DEBUG LAUNCH
echo   Log file: %LOG_FILE%
echo ============================================================
echo.

"%RELEASE_DIR%\G-Control.exe"

echo.
echo App closed. Log saved to: %LOG_FILE%
pause
