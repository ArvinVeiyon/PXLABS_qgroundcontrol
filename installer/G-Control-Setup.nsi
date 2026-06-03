; G-Control Setup — NSIS Installer Script
; Builds G-Control-Setup-v2.2.1.exe
; Requirements: NSIS 3.x  (makensis.exe in PATH or at default install location)
; Run: makensis G-Control-Setup.nsi  (from installer\ directory)

!define APP_NAME        "G-Control"
!define APP_VERSION     "2.2.1"
!define APP_PUBLISHER   "PXLABS"
!define APP_EXE         "G-Control.exe"
!define INSTALL_DIR     "$PROGRAMFILES64\G-Control"
!define REG_KEY         "Software\Microsoft\Windows\CurrentVersion\Uninstall\G-Control"

; Source directory (relative to this .nsi file)
!define SRC "..\build_clean\Release"

;----- General ----------------------------------------------------------------
Name          "${APP_NAME} ${APP_VERSION}"
OutFile       "G-Control-Setup-v${APP_VERSION}.exe"
InstallDir    "${INSTALL_DIR}"
InstallDirRegKey HKLM "${REG_KEY}" "InstallLocation"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
Unicode True

;----- Modern UI --------------------------------------------------------------
!addincludedir "."
!include "MUI2.nsh"
!include "EnvVarUpdate.nsh"

!define MUI_ABORTWARNING
!define MUI_ICON   "..\resources\icons\qgroundcontrol.ico"
!define MUI_UNICON "..\resources\icons\qgroundcontrol.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\LICENSE-GPL"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

;----- Install ----------------------------------------------------------------
Section "G-Control (required)" SecMain
    SectionIn RO
    SetRegView 64
    SetOutPath "$INSTDIR"

    ; ---- Main executable ----
    File "${SRC}\${APP_EXE}"

    ; ---- Qt + runtime DLLs ----
    File "${SRC}\*.dll"

    ; ---- Qt plugin subdirectories ----
    File /r "${SRC}\generic"
    File /r "${SRC}\geoservices"
    File /r "${SRC}\iconengines"
    File /r "${SRC}\imageformats"
    File /r "${SRC}\multimedia"
    File /r "${SRC}\networkinformation"
    File /r "${SRC}\platforminputcontexts"
    File /r "${SRC}\platforms"
    File /r "${SRC}\position"
    File /r "${SRC}\qml"
    File /r "${SRC}\sensors"
    File /r "${SRC}\sqldrivers"
    File /r "${SRC}\styles"
    File /r "${SRC}\texttospeech"
    File /r "${SRC}\tls"
    File /r "${SRC}\translations"

    ; ---- GStreamer plugins ----
    File /r "${SRC}\gstreamer-plugins"

    ; ---- PXLABS CLI (bundled exe, no Python required) ----
    SetOutPath "$INSTDIR\tools"
    File "${SRC}\tools\pxlabs_cli.exe"

    ; ---- Config (don't overwrite existing user config) ----
    SetOutPath "$INSTDIR\config"
    SetOverwrite off
    File "${SRC}\config\ssh_config.json"
    SetOverwrite on

    ; ---- GStreamer env var (user scope, no reboot needed) ----
    ${EnvVarUpdate} $0 "GST_PLUGIN_PATH" "A" "HKCU" "$INSTDIR\gstreamer-plugins"

    ; ---- Start Menu shortcut ----
    CreateDirectory "$SMPROGRAMS\G-Control"
    CreateShortcut "$SMPROGRAMS\G-Control\G-Control.lnk" \
        "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0 \
        SW_SHOWNORMAL "" "G-Control GCS"
    CreateShortcut "$SMPROGRAMS\G-Control\Uninstall G-Control.lnk" \
        "$INSTDIR\uninstall.exe"

    ; ---- Desktop shortcut ----
    CreateShortcut "$DESKTOP\G-Control.lnk" \
        "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0 \
        SW_SHOWNORMAL "" "G-Control GCS"

    ; ---- Uninstaller ----
    WriteUninstaller "$INSTDIR\uninstall.exe"

    ; ---- Add/Remove Programs entry ----
    WriteRegStr   HKLM "${REG_KEY}" "DisplayName"      "${APP_NAME} ${APP_VERSION}"
    WriteRegStr   HKLM "${REG_KEY}" "DisplayVersion"   "${APP_VERSION}"
    WriteRegStr   HKLM "${REG_KEY}" "Publisher"        "${APP_PUBLISHER}"
    WriteRegStr   HKLM "${REG_KEY}" "InstallLocation"  "$INSTDIR"
    WriteRegStr   HKLM "${REG_KEY}" "UninstallString"  "$INSTDIR\uninstall.exe"
    WriteRegStr   HKLM "${REG_KEY}" "DisplayIcon"      "$INSTDIR\${APP_EXE}"
    WriteRegDWORD HKLM "${REG_KEY}" "NoModify"         1
    WriteRegDWORD HKLM "${REG_KEY}" "NoRepair"         1
SectionEnd

;----- Uninstall --------------------------------------------------------------
Section "Uninstall"
    SetRegView 64
    ; Remove GST_PLUGIN_PATH
    ${un.EnvVarUpdate} $0 "GST_PLUGIN_PATH" "R" "HKCU" "$INSTDIR\gstreamer-plugins"

    ; Remove shortcuts
    Delete "$SMPROGRAMS\G-Control\G-Control.lnk"
    Delete "$SMPROGRAMS\G-Control\Uninstall G-Control.lnk"
    RMDir  "$SMPROGRAMS\G-Control"
    Delete "$DESKTOP\G-Control.lnk"

    ; Remove install dir (keep config so user settings survive)
    RMDir /r "$INSTDIR\generic"
    RMDir /r "$INSTDIR\geoservices"
    RMDir /r "$INSTDIR\gstreamer-plugins"
    RMDir /r "$INSTDIR\iconengines"
    RMDir /r "$INSTDIR\imageformats"
    RMDir /r "$INSTDIR\multimedia"
    RMDir /r "$INSTDIR\networkinformation"
    RMDir /r "$INSTDIR\platforminputcontexts"
    RMDir /r "$INSTDIR\platforms"
    RMDir /r "$INSTDIR\position"
    RMDir /r "$INSTDIR\qml"
    RMDir /r "$INSTDIR\sensors"
    RMDir /r "$INSTDIR\sqldrivers"
    RMDir /r "$INSTDIR\styles"
    RMDir /r "$INSTDIR\texttospeech"
    RMDir /r "$INSTDIR\tls"
    RMDir /r "$INSTDIR\translations"
    RMDir /r "$INSTDIR\tools"
    Delete   "$INSTDIR\*.dll"
    Delete   "$INSTDIR\${APP_EXE}"
    Delete   "$INSTDIR\uninstall.exe"
    ; NOTE: $INSTDIR\config\ is intentionally NOT deleted (preserves user SSH config)
    RMDir    "$INSTDIR"   ; only removes if empty (config dir remains = dir stays)

    ; Remove registry key
    DeleteRegKey HKLM "${REG_KEY}"
SectionEnd
