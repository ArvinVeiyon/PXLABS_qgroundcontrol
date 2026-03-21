/****************************************************************************
 *
 * (c) 2009-2020 QGROUNDCONTROL PROJECT <http://www.qgroundcontrol.org>
 *
 * QGroundControl is licensed according to the terms in the file
 * COPYING.md in the root of the source code directory.
 *
 ****************************************************************************/

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

import QGroundControl
import QGroundControl.Controls
import QGroundControl.Palette
import QGroundControl.MultiVehicleManager
import QGroundControl.ScreenTools
import QGroundControl.Controllers
import QGroundControl.PXLABS  // PXLABS

Rectangle {
    id:     _root
    width:  parent.width
    height: ScreenTools.toolbarHeight
    color:  qgcPal.toolbarBackground

    property var    _activeVehicle:     QGroundControl.multiVehicleManager.activeVehicle
    property bool   _communicationLost: _activeVehicle ? _activeVehicle.vehicleLinkManager.communicationLost : false
    property color  _mainStatusBGColor: qgcPal.brandingPurple

    // PXLABS: Air-TX temp state (companion only — relay is a passive receiver, no heat concern)
    property string _pxWifiTemp:     "—"
    property bool   _pxWifiFetch:    false
    property bool   _pxWifiEnabled:  false
    property int    _pxWifiInterval: 60

    // PXLABS: Connection status state
    property string _compStatus:        "—"   // "reachable" | "unreachable" | "—"
    property string _relayStatus:       "—"
    property bool   _statusFetch:       false
    property bool   _statusCheckPending: false  // queued when runner was busy
    property bool   _pxConnEnabled:     false
    property int    _pxConnInterval:    120

    function _pxFetchWifi() {
        if (PXLABSRunner.running) return
        // Mark background so user panels can abort-and-retry instead of seeing busy error
        QGroundControl.saveGlobalSetting("pxlabs_bg_active", "1")
        _pxWifiFetch = true
        // Do NOT reset _pxWifiTemp — keep last known value; only the ↻ spinner reflects activity
        PXLABSRunner.run("companion wifi-temp")
    }
    function _fetchStatus() {
        if (PXLABSRunner.running) {
            _statusCheckPending = true   // retry when current command finishes
            return
        }
        _statusCheckPending = false
        QGroundControl.saveGlobalSetting("pxlabs_bg_active", "1")
        _statusFetch = true
        PXLABSRunner.run("status")
    }
    function _pxLoadSettings() {
        _pxWifiEnabled  = (QGroundControl.loadGlobalSetting("pxlabs_wifi_temp_enabled",  "false") === "true")
        const s = parseInt(QGroundControl.loadGlobalSetting("pxlabs_wifi_temp_interval", "60"))
        _pxWifiInterval = isNaN(s) ? 60 : Math.max(5, s)   // 5 s floor only — user controls the value

        _pxConnEnabled  = (QGroundControl.loadGlobalSetting("pxlabs_conn_check_enabled",  "false") === "true")
        const ci = parseInt(QGroundControl.loadGlobalSetting("pxlabs_conn_check_interval", "120"))
        _pxConnInterval = isNaN(ci) ? 120 : Math.max(5, ci)  // same
    }

    // Air-TX temp auto-poll — interval fully controlled by user setting
    Timer {
        interval: Math.max(5, _root._pxWifiInterval) * 1000
        repeat:   true
        running:  _root._pxWifiEnabled
        onTriggered: _root._pxFetchWifi()
    }
    // Connection status: one-shot 5 s after startup (lets wifi-temp finish first)
    Timer {
        id:       pxStatusStartupTimer
        interval: 8000
        repeat:   false
        running:  false
        onTriggered: _root._fetchStatus()
    }
    // Connection status: periodic check — interval + enable from user settings
    Timer {
        interval: Math.max(5, _root._pxConnInterval) * 1000
        repeat:   true
        running:  _root._pxConnEnabled
        onTriggered: _root._fetchStatus()
    }

    Connections {
        target: PXLABSRunner

        function onOutputReady(text) {
            if (_root._statusFetch) {
                const lines = text.split('\n')
                for (let i = 0; i < lines.length; i++) {
                    const line = lines[i].trim()
                    if (line.startsWith("COMPANION:"))  _root._compStatus  = line.substring(10)
                    else if (line.startsWith("RELAY:")) _root._relayStatus = line.substring(6)
                }
                return
            }
            if (!_root._pxWifiFetch) return
            // Scan every line for a parseable number — robust to stderr mixed in
            const tlines = text.split('\n')
            for (let i = 0; i < tlines.length; i++) {
                const line = tlines[i].trim()
                if (line.length === 0) continue
                const v = parseFloat(line)
                if (!isNaN(v)) { _root._pxWifiTemp = line; return }
            }
        }

        function onCommandFinished(exitCode) {
            if (_root._statusFetch) {
                _root._statusFetch = false
                QGroundControl.saveGlobalSetting("pxlabs_bg_active", "0")
            } else if (_root._pxWifiFetch) {
                _root._pxWifiFetch = false
                // Only set unavailable if we never received any real value yet
                if (exitCode !== 0 && _root._pxWifiTemp === "—") _root._pxWifiTemp = "N/A"
                QGroundControl.saveGlobalSetting("pxlabs_bg_active", "0")
            }
            if (_root._statusCheckPending) Qt.callLater(_root._fetchStatus)
        }

        function onCommandFailed(errorText) {
            if (_root._statusFetch) {
                _root._statusFetch = false
                QGroundControl.saveGlobalSetting("pxlabs_bg_active", "0")
            } else if (_root._pxWifiFetch) {
                _root._pxWifiFetch = false
                // On abort (kill) keep the last known value — don't show N/A for a good reading
                // On genuine failure only set N/A if we never had a value
                const wasKilled = errorText.indexOf("killed") >= 0 || errorText.indexOf("crashed") >= 0
                if (!wasKilled && _root._pxWifiTemp === "—") _root._pxWifiTemp = "N/A"
                QGroundControl.saveGlobalSetting("pxlabs_bg_active", "0")
            }
            if (_root._statusCheckPending) Qt.callLater(_root._fetchStatus)
        }
    }

    Component.onCompleted: {
        _pxLoadSettings()
        QGroundControl.saveGlobalSetting("pxlabs_bg_active", "0")  // reset stale flag on start
        Qt.callLater(_pxFetchWifi)
        pxStatusStartupTimer.start()
    }

    function dropMainStatusIndicatorTool() {
        mainStatusIndicator.dropMainStatusIndicator();
    }

    QGCPalette { id: qgcPal }

    /// Bottom single pixel divider
    Rectangle {
        anchors.left:   parent.left
        anchors.right:  parent.right
        anchors.bottom: parent.bottom
        height:         1
        color:          "black"
        visible:        qgcPal.globalTheme === QGCPalette.Light
    }

    Rectangle {
        anchors.fill: viewButtonRow
        
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0;                                     color: _mainStatusBGColor }
            GradientStop { position: currentButton.x + currentButton.width; color: _mainStatusBGColor }
            GradientStop { position: 1;                                     color: _root.color }
        }
    }

    RowLayout {
        id:                     viewButtonRow
        anchors.bottomMargin:   1
        anchors.top:            parent.top
        anchors.bottom:         parent.bottom
        spacing:                ScreenTools.defaultFontPixelWidth / 2

        QGCToolBarButton {
            id:                     currentButton
            Layout.preferredHeight: viewButtonRow.height
            icon.source:            "/res/QGCLogoFull.svg"
            logo:                   true
            onClicked:              mainWindow.showToolSelectDialog()
        }

        MainStatusIndicator {
            id: mainStatusIndicator
            Layout.preferredHeight: viewButtonRow.height
        }

        QGCButton {
            id:                 disconnectButton
            text:               qsTr("Disconnect")
            onClicked:          _activeVehicle.closeVehicle()
            visible:            _activeVehicle && _communicationLost
        }
    }

    QGCFlickable {
        id:                     toolsFlickable
        anchors.leftMargin:     ScreenTools.defaultFontPixelWidth * ScreenTools.largeFontPointRatio * 1.5
        anchors.rightMargin:    ScreenTools.defaultFontPixelWidth / 2
        anchors.left:           viewButtonRow.right
        anchors.bottomMargin:   1
        anchors.top:            parent.top
        anchors.bottom:         parent.bottom
        anchors.right:          parent.right
        contentWidth:           toolIndicators.width
        flickableDirection:     Flickable.HorizontalFlick

        FlyViewToolBarIndicators { id: toolIndicators }
    }

    //-------------------------------------------------------------------------
    //-- PXLABS: Connection Status Chip (Companion + Relay, left of Air-TX chip)
    Rectangle {
        id:                     pxConnChip
        z:                      20
        anchors.right:          pxAirTxChip.left
        anchors.rightMargin:    ScreenTools.defaultFontPixelWidth * 0.6
        anchors.verticalCenter: parent.verticalCenter
        height:                 ScreenTools.defaultFontPixelHeight * 2.0
        width:                  pxConnRow.implicitWidth + ScreenTools.defaultFontPixelWidth * 2.4
        radius:                 height * 0.3
        color:                  qgcPal.toolbarBackground
        border.color:           qgcPal.text
        border.width:           1
        opacity:                0.92

        RowLayout {
            id:               pxConnRow
            anchors.centerIn: parent
            spacing:          ScreenTools.defaultFontPixelWidth * 0.8

            // Companion status
            RowLayout {
                spacing: ScreenTools.defaultFontPixelWidth * 0.3
                QGCLabel {
                    text:           "●"
                    color:          _root._compStatus === "reachable"   ? qgcPal.colorGreen :
                                    _root._compStatus === "unreachable" ? qgcPal.colorRed   : qgcPal.colorGrey
                    font.pointSize: ScreenTools.defaultFontPointSize
                }
                QGCLabel {
                    text:           "Comp"
                    color:          qgcPal.text
                    font.pointSize: ScreenTools.defaultFontPointSize
                    font.bold:      true
                }
            }

            // Divider
            Rectangle {
                width:   1
                height:  ScreenTools.defaultFontPixelHeight * 1.0
                color:   qgcPal.text
                opacity: 0.3
            }

            // Relay status
            RowLayout {
                spacing: ScreenTools.defaultFontPixelWidth * 0.3
                QGCLabel {
                    text:           "●"
                    color:          _root._relayStatus === "reachable"   ? qgcPal.colorGreen :
                                    _root._relayStatus === "unreachable" ? qgcPal.colorRed   : qgcPal.colorGrey
                    font.pointSize: ScreenTools.defaultFontPointSize
                }
                QGCLabel {
                    text:           "Relay"
                    color:          qgcPal.text
                    font.pointSize: ScreenTools.defaultFontPointSize
                    font.bold:      true
                }
            }

            // Refresh spinner
            QGCLabel {
                text:           _root._statusFetch ? "…" : "↻"
                color:          qgcPal.colorGrey
                font.pointSize: ScreenTools.defaultFontPointSize
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape:  Qt.PointingHandCursor
            onClicked:    _root._fetchStatus()
        }
    }

    //-------------------------------------------------------------------------
    //-- PXLABS: Air-TX Temp Chip (left of PXLABS brand chip)
    Rectangle {
        id:                     pxAirTxChip
        z:                      20
        anchors.right:          pxLabsChip.left
        anchors.rightMargin:    ScreenTools.defaultFontPixelWidth * 0.6
        anchors.verticalCenter: parent.verticalCenter
        height:                 ScreenTools.defaultFontPixelHeight * 2.0
        width:                  Math.max(pxAirTxRow.implicitWidth + ScreenTools.defaultFontPixelWidth * 2.4,
                                         ScreenTools.defaultFontPixelWidth * 11)
        radius:                 height * 0.3
        color:                  qgcPal.toolbarBackground
        border.color:           qgcPal.text
        border.width:           1
        opacity:                0.92

        RowLayout {
            id:               pxAirTxRow
            anchors.centerIn: parent
            spacing:          ScreenTools.defaultFontPixelWidth * 0.5

            QGCLabel {
                text: {
                    const v = parseFloat(_root._pxWifiTemp)
                    return isNaN(v) ? ("Air-TX  " + _root._pxWifiTemp)
                                    : ("Air-TX  " + _root._pxWifiTemp + " °C")
                }
                color: {
                    const v = parseFloat(_root._pxWifiTemp)
                    if (isNaN(v))  return qgcPal.colorGrey
                    if (v >= 75)   return qgcPal.colorRed
                    if (v >= 60)   return qgcPal.colorOrange
                    return qgcPal.colorGreen
                }
                font.pointSize: ScreenTools.defaultFontPointSize
                font.bold:      true
            }

            QGCLabel {
                text:           _root._pxWifiFetch ? "…" : "↻"
                color:          qgcPal.colorGrey
                font.pointSize: ScreenTools.defaultFontPointSize
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape:  Qt.PointingHandCursor
            onClicked:    _root._pxFetchWifi()
        }
    }

    //-------------------------------------------------------------------------
    //-- PXLABS: Brand chip — between Air-TX and PX4 logo
    Rectangle {
        id:                     pxLabsChip
        z:                      20
        anchors.right:          brandImage.visible ? brandImage.left : parent.right
        anchors.rightMargin:    ScreenTools.defaultFontPixelWidth * 0.8
        anchors.verticalCenter: parent.verticalCenter
        height:                 ScreenTools.defaultFontPixelHeight * 2.0
        width:                  pxLabsRow.implicitWidth + ScreenTools.defaultFontPixelWidth * 2.0
        radius:                 height * 0.3
        border.width:           1
        border.color:           Qt.rgba(0.3, 0.6, 1.0, 0.7)
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(0.10, 0.18, 0.38, 0.95) }
            GradientStop { position: 1.0; color: Qt.rgba(0.06, 0.10, 0.24, 0.95) }
        }

        RowLayout {
            id:               pxLabsRow
            anchors.centerIn: parent
            spacing:          ScreenTools.defaultFontPixelWidth * 0.15

            QGCLabel {
                text:           "PX"
                color:          "#FFD700"
                font.pointSize: ScreenTools.defaultFontPointSize
                font.bold:      true
            }
            QGCLabel {
                text:           "Labs"
                color:          "#8BBFFF"
                font.pointSize: ScreenTools.defaultFontPointSize
                font.bold:      true
            }
        }
    }

    //-------------------------------------------------------------------------
    //-- Branding Logo
    Image {
        id:                     brandImage
        anchors.right:          parent.right
        anchors.top:            parent.top
        anchors.bottom:         parent.bottom
        anchors.margins:        ScreenTools.defaultFontPixelHeight * 0.66
        visible:                _activeVehicle && !_communicationLost && x > (toolsFlickable.x + toolsFlickable.contentWidth + ScreenTools.defaultFontPixelWidth)
        fillMode:               Image.PreserveAspectFit
        source:                 _outdoorPalette ? _brandImageOutdoor : _brandImageIndoor
        mipmap:                 true

        property bool   _outdoorPalette:        qgcPal.globalTheme === QGCPalette.Light
        property bool   _corePluginBranding:    QGroundControl.corePlugin.brandImageIndoor.length != 0
        property string _userBrandImageIndoor:  QGroundControl.settingsManager.brandImageSettings.userBrandImageIndoor.value
        property string _userBrandImageOutdoor: QGroundControl.settingsManager.brandImageSettings.userBrandImageOutdoor.value
        property bool   _userBrandingIndoor:    QGroundControl.settingsManager.brandImageSettings.visible && _userBrandImageIndoor.length != 0
        property bool   _userBrandingOutdoor:   QGroundControl.settingsManager.brandImageSettings.visible && _userBrandImageOutdoor.length != 0
        property string _brandImageIndoor:      brandImageIndoor()
        property string _brandImageOutdoor:     brandImageOutdoor()

        function brandImageIndoor() {
            if (_userBrandingIndoor) {
                return _userBrandImageIndoor
            } else {
                if (_userBrandingOutdoor) {
                    return _userBrandImageOutdoor
                } else {
                    if (_corePluginBranding) {
                        return QGroundControl.corePlugin.brandImageIndoor
                    } else {
                        return _activeVehicle ? _activeVehicle.brandImageIndoor : ""
                    }
                }
            }
        }

        function brandImageOutdoor() {
            if (_userBrandingOutdoor) {
                return _userBrandImageOutdoor
            } else {
                if (_userBrandingIndoor) {
                    return _userBrandImageIndoor
                } else {
                    if (_corePluginBranding) {
                        return QGroundControl.corePlugin.brandImageOutdoor
                    } else {
                        return _activeVehicle ? _activeVehicle.brandImageOutdoor : ""
                    }
                }
            }
        }
    }

    // Small parameter download progress bar
    Rectangle {
        anchors.bottom: parent.bottom
        height:         _root.height * 0.05
        width:          _activeVehicle ? _activeVehicle.loadProgress * parent.width : 0
        color:          qgcPal.colorGreen
        visible:        !largeProgressBar.visible
    }

    // Large parameter download progress bar
    Rectangle {
        id:             largeProgressBar
        anchors.bottom: parent.bottom
        anchors.left:   parent.left
        anchors.right:  parent.right
        height:         parent.height
        color:          qgcPal.window
        visible:        _showLargeProgress

        property bool _initialDownloadComplete: _activeVehicle ? _activeVehicle.initialConnectComplete : true
        property bool _userHide:                false
        property bool _showLargeProgress:       !_initialDownloadComplete && !_userHide && qgcPal.globalTheme === QGCPalette.Light

        Connections {
            target:                 QGroundControl.multiVehicleManager
            function onActiveVehicleChanged(activeVehicle) { largeProgressBar._userHide = false }
        }

        Rectangle {
            anchors.top:    parent.top
            anchors.bottom: parent.bottom
            width:          _activeVehicle ? _activeVehicle.loadProgress * parent.width : 0
            color:          qgcPal.colorGreen
        }

        QGCLabel {
            anchors.centerIn:   parent
            text:               qsTr("Downloading")
            font.pointSize:     ScreenTools.largeFontPointSize
        }

        QGCLabel {
            anchors.margins:    _margin
            anchors.right:      parent.right
            anchors.bottom:     parent.bottom
            text:               qsTr("Click anywhere to hide")

            property real _margin: ScreenTools.defaultFontPixelWidth / 2
        }

        MouseArea {
            anchors.fill:   parent
            onClicked:      largeProgressBar._userHide = true
        }
    }
}
