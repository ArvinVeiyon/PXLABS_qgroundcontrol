/****************************************************************************
 *
 * PXLABS G-Control — FlyView custom layer
 * - "System Control" panel (Companion + Relay power/SSH + WFB mode)
 *   Fixed to right edge, resizable via edge/corner handles.
 * - Draggable camera-switch panel (drag via header only)
 * - Wi-Fi Temp chip lives in FlyViewToolBar.qml (toolbar, left of PX4 logo)
 *
 ****************************************************************************/

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQml.Models

import QGroundControl
import QGroundControl.Controllers
import QGroundControl.Controls
import QGroundControl.FactSystem
import QGroundControl.FlightDisplay
import QGroundControl.FlightMap
import QGroundControl.Palette
import QGroundControl.ScreenTools
import QGroundControl.Vehicle
import QGroundControl.PXLABS

Item {
    id: _root

    property var parentToolInsets
    property var totalToolInsets:   _toolInsets
    property var mapControl

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------
    property bool   _panelInitDone:   false
    property bool   _rightPanelOpen:  false
    // WFB mode: "standalone" | "cluster" | "" — never persisted, always fetched fresh
    property string _wfbMode:        ""
    property bool   _wfbStatusFetch: false   // true while querying relay wfb status
    property bool   _wfbInitFetched: false   // true after first fetch since app start

    // Fetch WFB mode once the first time the panel is opened
    property bool panelOpenWatcher: _rightPanelOpen
    onPanelOpenWatcherChanged: {
        if (panelOpenWatcher && !_wfbInitFetched)
            Qt.callLater(_checkWfbMode)
    }

    // Panel status (SSH / other panel commands)
    property string _panelStatus:    ""
    property bool   _panelCmdActive: false
    property string _panelRetryArgs:   ""
    property string _panelRetryStatus: ""
    property string _lastPanelCmd:     ""

    // Abort-and-retry: after aborting a background poll, re-run the queued panel command
    Timer {
        id:       _panelRetryTimer
        interval: 400
        repeat:   false
        onTriggered: {
            if (PXLABSRunner.running) return
            _root._panelStatus    = _root._panelRetryStatus
            _root._panelCmdActive = true
            _root._lastPanelCmd   = _root._panelRetryArgs
            PXLABSRunner.run(_root._panelRetryArgs)
        }
    }

    // Auto-clear status 2.5 s after a successful command
    Timer {
        id:       _panelStatusClearTimer
        interval: 2500
        repeat:   false
        onTriggered: _root._panelStatus = ""
    }

    readonly property real _pad:     ScreenTools.defaultFontPixelWidth
    readonly property real _rpWidth: ScreenTools.defaultFontPixelWidth * 28   // default content width
    readonly property real _tabW:    ScreenTools.defaultFontPixelWidth * 2.2
    readonly property real _btnH:    ScreenTools.defaultFontPixelHeight * 2.5
    readonly property real _sshBtnH: ScreenTools.defaultFontPixelHeight * 2.2

    // Resizable panel geometry
    property real   _rpContentW:     ScreenTools.defaultFontPixelWidth * 28
    readonly property real _rpMinW:  ScreenTools.defaultFontPixelWidth * 18
    readonly property real _rpMinH:  ScreenTools.defaultFontPixelHeight * 15
    readonly property real _rpHdrH:  ScreenTools.defaultFontPixelHeight * 2.5   // header height
    // Camera panel
    readonly property real _camW:    ScreenTools.defaultFontPixelWidth  * 22
    readonly property real _camBtnH: ScreenTools.defaultFontPixelHeight * 2.4

    // -----------------------------------------------------------------------
    // WFB post-switch check timer (waits for relay switch to settle)
    // -----------------------------------------------------------------------
    Timer {
        id:       wfbCheckTimer
        interval: 4000
        repeat:   false
        onTriggered: _root._checkWfbMode()
    }

    // -----------------------------------------------------------------------
    // Helpers — camera panel
    // -----------------------------------------------------------------------
    function _clamp(p) {
        if (!p) return
        if (p.x < 0)                    p.x = 0
        if (p.y < 0)                    p.y = 0
        if (p.x + p.width  > width)     p.x = Math.max(0, width  - p.width)
        if (p.y + p.height > height)    p.y = Math.max(0, height - p.height)
    }

    function _defaultCamX() { return _pad * 2 }
    function _defaultCamY() {
        return Math.max(0, _root.height - cameraPanel.height
                           - _toolInsets.bottomEdgeLeftInset - _pad * 4)
    }

    function _savePos() {
        if (!_panelInitDone) return
        QGroundControl.saveGlobalSetting("pxlabs_cam_x", Math.round(cameraPanel.x).toString())
        QGroundControl.saveGlobalSetting("pxlabs_cam_y", Math.round(cameraPanel.y).toString())
    }

    function _restorePos() {
        const cx = parseInt(QGroundControl.loadGlobalSetting("pxlabs_cam_x", "-1"))
        const cy = parseInt(QGroundControl.loadGlobalSetting("pxlabs_cam_y", "-1"))
        cameraPanel.x = (cx >= 0) ? cx : _defaultCamX()
        cameraPanel.y = (cy >= 0) ? cy : _defaultCamY()
        _clamp(cameraPanel)
        _panelInitDone = true
        _savePos()
    }

    // -----------------------------------------------------------------------
    // Helpers — System Control panel layout
    // -----------------------------------------------------------------------
    // Position panel flush against right edge
    function _updateRpX() {
        rightPanel.x = Math.max(0, _root.width - rightPanel.width)
    }

    function _saveRpLayout() {
        if (!_panelInitDone) return
        QGroundControl.saveGlobalSetting("pxlabs_rp_y", Math.round(rightPanel.y).toString())
        QGroundControl.saveGlobalSetting("pxlabs_rp_w", Math.round(_rpContentW).toString())
        QGroundControl.saveGlobalSetting("pxlabs_rp_h", Math.round(rightPanel.height).toString())
    }

    function _restoreRpLayout() {
        const sy = parseInt(QGroundControl.loadGlobalSetting("pxlabs_rp_y", "-1"))
        const sw = parseInt(QGroundControl.loadGlobalSetting("pxlabs_rp_w", "-1"))
        const sh = parseInt(QGroundControl.loadGlobalSetting("pxlabs_rp_h", "-1"))
        _rpContentW       = (sw >= _rpMinW) ? sw : _rpWidth
        const defH        = Math.max(_rpMinH,
                                     _root.height
                                     - _toolInsets.topEdgeRightInset
                                     - _toolInsets.bottomEdgeRightInset
                                     - ScreenTools.defaultFontPixelHeight * 7)
        rightPanel.height = (sh >= _rpMinH) ? sh : defH
        rightPanel.y      = (sy >= 0) ? sy : (_toolInsets.topEdgeRightInset + ScreenTools.defaultFontPixelHeight * 7)
        _clampRpY()
        _updateRpX()
    }

    // Clamp Y only — X is always determined by side
    function _clampRpY() {
        rightPanel.y = Math.max(0, Math.min(rightPanel.y, _root.height - rightPanel.height))
    }

    // -----------------------------------------------------------------------
    // Other helpers
    // -----------------------------------------------------------------------
    function _confirm(title, msg, cmd) {
        mainWindow.showMessageDialog(title, msg, Dialog.Yes | Dialog.No,
                                     function() { PXLABSRunner.run(cmd) })
    }

    function _runPanelCmd(args, statusMsg) {
        if (PXLABSRunner.running) {
            if (QGroundControl.loadGlobalSetting("pxlabs_bg_active", "0") === "1") {
                // Background poll running — abort it and retry automatically
                _panelRetryArgs   = args
                _panelRetryStatus = statusMsg
                _panelStatus      = "Waiting…"
                PXLABSRunner.abort()
                _panelRetryTimer.start()
            } else {
                _panelStatus = "⚠ Busy — retry in a moment"
            }
            return
        }
        _panelStatus    = statusMsg
        _panelCmdActive = true
        _lastPanelCmd   = args
        PXLABSRunner.run(args)
    }

    function _checkWfbMode() {
        if (PXLABSRunner.running) return
        _wfbInitFetched  = true
        _wfbStatusFetch  = true
        PXLABSRunner.run("relay wfb refresh")   // outputs SA:active/inactive, CA:active/inactive
    }

    // -----------------------------------------------------------------------
    // Runner output routing
    // -----------------------------------------------------------------------
    Connections {
        target: PXLABSRunner

        function onOutputReady(text) {
            if (_wfbStatusFetch) {
                var saMatch = text.match(/^SA:(\S+)/m)
                var caMatch = text.match(/^CA:(\S+)/m)
                if (saMatch && caMatch) {
                    var sa = saMatch[1]
                    var ca = caMatch[1]
                    var newMode = ""
                    if (sa === "active" && ca !== "active")       newMode = "standalone"
                    else if (ca === "active" && sa !== "active")  newMode = "cluster"
                    else if (sa === "active" && ca === "active")  newMode = "standalone"
                    if (newMode !== "") {
                        _root._wfbMode = newMode
                    }
                }
                return
            }
            if (_panelCmdActive) {
                const t = text.trim()
                if (t.length > 0) _panelStatus = t
            }
        }

        function onCommandFinished(exitCode) {
            if (_wfbStatusFetch) {
                _wfbStatusFetch = false
                return
            }
            if (_panelCmdActive) {
                _panelCmdActive = false
                if (exitCode !== 0) {
                    _panelStatus = "✗ Failed (exit " + exitCode + ")"
                } else {
                    if (_root._lastPanelCmd.indexOf("ssh-terminal") >= 0)
                        _panelStatus = "✓ Terminal opened"
                    _panelStatusClearTimer.restart()
                }
            }
        }

        function onCommandFailed(errorText) {
            if (_wfbStatusFetch) {
                _wfbStatusFetch = false
                return
            }
            if (_panelCmdActive) {
                _panelCmdActive = false
                _panelStatus = "✗ Error: " + errorText
            }
        }
    }

    // -----------------------------------------------------------------------
    // Tool insets — pass-through
    // -----------------------------------------------------------------------
    QGCToolInsets {
        id:                     _toolInsets
        leftEdgeTopInset:       parentToolInsets.leftEdgeTopInset
        leftEdgeCenterInset:    parentToolInsets.leftEdgeCenterInset
        leftEdgeBottomInset:    parentToolInsets.leftEdgeBottomInset
        rightEdgeTopInset:      parentToolInsets.rightEdgeTopInset
        rightEdgeCenterInset:   parentToolInsets.rightEdgeCenterInset
        rightEdgeBottomInset:   parentToolInsets.rightEdgeBottomInset
        topEdgeLeftInset:       parentToolInsets.topEdgeLeftInset
        topEdgeCenterInset:     parentToolInsets.topEdgeCenterInset
        topEdgeRightInset:      parentToolInsets.topEdgeRightInset
        bottomEdgeLeftInset:    parentToolInsets.bottomEdgeLeftInset
        bottomEdgeCenterInset:  parentToolInsets.bottomEdgeCenterInset
        bottomEdgeRightInset:   parentToolInsets.bottomEdgeRightInset
    }

    // -----------------------------------------------------------------------
    // System Control panel — draggable + resizable
    // -----------------------------------------------------------------------
    Rectangle {
        id:     rightPanel
        z:      10
        x:      0          // managed by _restoreRpLayout
        y:      0          // managed by _restoreRpLayout
        width:  _rightPanelOpen ? _rpContentW + _tabW : _tabW
        height: 300        // managed by _restoreRpLayout

        color:        Qt.rgba(0.04, 0.06, 0.10, 0.93)
        border.color: Qt.rgba(0.3, 0.6, 1.0, 0.18)
        border.width: 1
        clip:         true
        onWidthChanged: _root._updateRpX()   // re-pin to edge when panel opens/closes

        // ── Pull tab (left edge when side=left, right edge when side=right) ─
        Rectangle {
            id:     pullTab
            width:  _tabW
            height: ScreenTools.defaultFontPixelHeight * 6.5
            radius: 3
            x:             parent.width - _tabW
            anchors.top:       parent.top
            anchors.topMargin: ScreenTools.defaultFontPixelHeight * 2
            color: tabMa.pressed       ? Qt.rgba(0.3,0.6,1.0,0.28) :
                   tabMa.containsMouse ? Qt.rgba(0.3,0.6,1.0,0.16) : Qt.rgba(1,1,1,0.06)
            border.color: Qt.rgba(0.3,0.6,1.0,0.35); border.width: 1

            Column {
                anchors.centerIn: parent
                spacing: 2

                QGCLabel {
                    visible:                  !_rightPanelOpen
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:  _root._wfbMode === "standalone" ? "◉" :
                           _root._wfbMode === "cluster"    ? "⬡" : "⊙"
                    color: _root._wfbMode === "standalone" ? "#5AFF7A" :
                           _root._wfbMode === "cluster"    ? "#5AB4FF" : Qt.rgba(1,1,1,0.3)
                    font.pointSize: ScreenTools.smallFontPointSize
                }

                QGCLabel {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text:  _rightPanelOpen ? "›" : "‹"
                    color: "#8BBFFF"
                    font.pointSize: ScreenTools.defaultFontPointSize + 2
                    font.bold: true
                }
            }

            MouseArea {
                id: tabMa; anchors.fill: parent
                hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: _rightPanelOpen = !_rightPanelOpen
            }
        }

        // ── Content (opposite side of pull tab) ───────────────────────────
        Item {
            id:             rpContent
            x:              0
            width:          parent.width - _tabW
            anchors.top:    parent.top
            anchors.bottom: parent.bottom
            visible:        _rightPanelOpen
            clip:           true

            // ── Header ──
            Item {
                id:     rpHeader
                width:  parent.width
                height: _rpHdrH

                RowLayout {
                    anchors { fill: parent; leftMargin: _pad * 0.6; rightMargin: _pad * 0.6 }
                    spacing: _pad * 0.4

                    QGCLabel {
                        text:           "⚡  System Control"
                        font.bold:      true
                        font.pointSize: ScreenTools.defaultFontPointSize + 0.5
                        color:          "#8BBFFF"
                        Layout.fillWidth: true
                    }
                    QGCLabel {
                        text:           "⤢"
                        color:          Qt.rgba(0.5, 0.7, 1.0, 0.4)
                        font.pointSize: ScreenTools.smallFontPointSize
                    }
                }
            }

            // Header separator
            Rectangle {
                id:     rpSep
                width:  parent.width
                height: 1
                anchors.top: rpHeader.bottom
                color:       Qt.rgba(0.3, 0.6, 1.0, 0.35)
            }

            // ── Scrollable content ──
            Flickable {
                anchors.top:    rpSep.bottom
                anchors.left:   parent.left
                anchors.right:  parent.right
                anchors.bottom: parent.bottom
                contentHeight:  panelCol.implicitHeight + _pad * 2
                contentWidth:   width
                flickableDirection: Flickable.VerticalFlick
                clip: true

                ColumnLayout {
                    id:              panelCol
                    width:           parent.width
                    anchors.top:     parent.top
                    anchors.left:    parent.left
                    anchors.right:   parent.right
                    anchors.margins: _pad
                    spacing:         _pad * 0.7

                    // ── Companion ──────────────────────────────────────
                    QGCLabel {
                        text: "Companion"
                        font.pointSize: ScreenTools.smallFontPointSize; font.bold: true
                        color: Qt.rgba(1,1,1,0.55); Layout.fillWidth: true; leftPadding: _pad * 0.3
                    }

                    // Restart Companion
                    Rectangle {
                        Layout.fillWidth: true; height: _btnH; radius: 5
                        gradient: Gradient { orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: cmpRstMa.pressed?"#C88000":cmpRstMa.containsMouse?"#B07000":"#7A4E00" }
                            GradientStop { position: 1.0; color: cmpRstMa.pressed?"#A06800":cmpRstMa.containsMouse?"#8A5800":"#5A3800" } }
                        border.color: Qt.rgba(1,0.65,0,0.5); border.width: 1
                        RowLayout { anchors.centerIn: parent; spacing: _pad * 0.5
                            QGCLabel { text: "↺"; color: "white"; font.pointSize: ScreenTools.smallFontPointSize+1; font.bold: true }
                            QGCLabel { text: "Restart Companion"; color: "white"; font.pointSize: ScreenTools.smallFontPointSize; font.bold: true } }
                        MouseArea { id: cmpRstMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: _confirm("Companion Restart","Reboot companion now?","companion reboot") }
                    }

                    // Shutdown Companion
                    Rectangle {
                        Layout.fillWidth: true; height: _btnH; radius: 5
                        gradient: Gradient { orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: cmpShtMa.pressed?"#CC2222":cmpShtMa.containsMouse?"#B52020":"#7A1515" }
                            GradientStop { position: 1.0; color: cmpShtMa.pressed?"#AA1818":cmpShtMa.containsMouse?"#951818":"#5A0F0F" } }
                        border.color: Qt.rgba(1,0.2,0.2,0.5); border.width: 1
                        RowLayout { anchors.centerIn: parent; spacing: _pad * 0.5
                            QGCLabel { text: "⏻"; color: "white"; font.pointSize: ScreenTools.smallFontPointSize+1; font.bold: true }
                            QGCLabel { text: "Shutdown Companion"; color: "white"; font.pointSize: ScreenTools.smallFontPointSize; font.bold: true } }
                        MouseArea { id: cmpShtMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: _confirm("Companion Shutdown","Shutdown companion now?","companion shutdown") }
                    }

                    // SSH Companion
                    Rectangle {
                        Layout.fillWidth: true; height: _sshBtnH; radius: 5
                        gradient: Gradient { orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: cmpSshMa.pressed?"#1090A8":cmpSshMa.containsMouse?"#0C7890":"#065060" }
                            GradientStop { position: 1.0; color: cmpSshMa.pressed?"#0C7890":cmpSshMa.containsMouse?"#085870":"#043840" } }
                        border.color: Qt.rgba(0.1,0.8,1.0,0.5); border.width: 1
                        RowLayout { anchors.centerIn: parent; spacing: _pad * 0.5
                            QGCLabel { text: ">_"; color: "#7EEEFF"; font.pointSize: ScreenTools.smallFontPointSize; font.bold: true; font.family: "Courier New" }
                            QGCLabel { text: "SSH Companion"; color: "white"; font.pointSize: ScreenTools.smallFontPointSize; font.bold: true } }
                        MouseArea { id: cmpSshMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: _runPanelCmd("companion ssh-terminal", "Opening SSH terminal…") }
                    }

                    Rectangle { Layout.fillWidth: true; height: 1; color: Qt.rgba(1,1,1,0.08) }

                    // ── Relay Station ───────────────────────────────────
                    QGCLabel {
                        text: "Relay Station"
                        font.pointSize: ScreenTools.smallFontPointSize; font.bold: true
                        color: Qt.rgba(1,1,1,0.55); Layout.fillWidth: true; leftPadding: _pad * 0.3
                    }

                    // Restart Relay
                    Rectangle {
                        Layout.fillWidth: true; height: _btnH; radius: 5
                        gradient: Gradient { orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: relRstMa.pressed?"#C88000":relRstMa.containsMouse?"#B07000":"#7A4E00" }
                            GradientStop { position: 1.0; color: relRstMa.pressed?"#A06800":relRstMa.containsMouse?"#8A5800":"#5A3800" } }
                        border.color: Qt.rgba(1,0.65,0,0.5); border.width: 1
                        RowLayout { anchors.centerIn: parent; spacing: _pad * 0.5
                            QGCLabel { text: "↺"; color: "white"; font.pointSize: ScreenTools.smallFontPointSize+1; font.bold: true }
                            QGCLabel { text: "Restart Relay"; color: "white"; font.pointSize: ScreenTools.smallFontPointSize; font.bold: true } }
                        MouseArea { id: relRstMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: _confirm("Relay Restart","Reboot relay station now?","relay reboot") }
                    }

                    // Shutdown Relay
                    Rectangle {
                        Layout.fillWidth: true; height: _btnH; radius: 5
                        gradient: Gradient { orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: relShtMa.pressed?"#CC2222":relShtMa.containsMouse?"#B52020":"#7A1515" }
                            GradientStop { position: 1.0; color: relShtMa.pressed?"#AA1818":relShtMa.containsMouse?"#951818":"#5A0F0F" } }
                        border.color: Qt.rgba(1,0.2,0.2,0.5); border.width: 1
                        RowLayout { anchors.centerIn: parent; spacing: _pad * 0.5
                            QGCLabel { text: "⏻"; color: "white"; font.pointSize: ScreenTools.smallFontPointSize+1; font.bold: true }
                            QGCLabel { text: "Shutdown Relay"; color: "white"; font.pointSize: ScreenTools.smallFontPointSize; font.bold: true } }
                        MouseArea { id: relShtMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: _confirm("Relay Shutdown","Shutdown relay station now?","relay shutdown") }
                    }

                    // SSH Relay
                    Rectangle {
                        Layout.fillWidth: true; height: _sshBtnH; radius: 5
                        gradient: Gradient { orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: relSshMa.pressed?"#1090A8":relSshMa.containsMouse?"#0C7890":"#065060" }
                            GradientStop { position: 1.0; color: relSshMa.pressed?"#0C7890":relSshMa.containsMouse?"#085870":"#043840" } }
                        border.color: Qt.rgba(0.1,0.8,1.0,0.5); border.width: 1
                        RowLayout { anchors.centerIn: parent; spacing: _pad * 0.5
                            QGCLabel { text: ">_"; color: "#7EEEFF"; font.pointSize: ScreenTools.smallFontPointSize; font.bold: true; font.family: "Courier New" }
                            QGCLabel { text: "SSH Relay"; color: "white"; font.pointSize: ScreenTools.smallFontPointSize; font.bold: true } }
                        MouseArea { id: relSshMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: _runPanelCmd("relay ssh-terminal", "Opening SSH terminal…") }
                    }

                    Rectangle { Layout.fillWidth: true; height: 1; color: Qt.rgba(1,1,1,0.08) }

                    // ── WFB Mode ────────────────────────────────────────
                    RowLayout {
                        Layout.fillWidth: true; spacing: _pad * 0.4
                        QGCLabel {
                            text: "WFB Mode"
                            font.pointSize: ScreenTools.smallFontPointSize; font.bold: true
                            color: Qt.rgba(1,1,1,0.55); leftPadding: _pad * 0.3; Layout.fillWidth: true
                        }
                        Rectangle {
                            width: ScreenTools.defaultFontPixelWidth * 8; height: ScreenTools.defaultFontPixelHeight * 1.5; radius: 4
                            color: rRefMa.pressed ? Qt.rgba(0.3,0.5,0.8,0.4) : rRefMa.containsMouse ? Qt.rgba(0.3,0.5,0.8,0.25) : Qt.rgba(0.2,0.3,0.5,0.18)
                            border.color: Qt.rgba(0.3,0.6,1.0,0.5); border.width: 1
                            QGCLabel { anchors.centerIn: parent; text: _root._wfbStatusFetch ? "…" : "↻ Refresh"
                                color: "#8BBFFF"; font.pointSize: ScreenTools.smallFontPointSize; font.bold: true }
                            MouseArea { id: rRefMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: _root._checkWfbMode() }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: _pad * 0.6

                        // Standalone
                        Rectangle {
                            Layout.fillWidth: true; height: _btnH; radius: 5
                            property bool _active: _root._wfbMode === "standalone"
                            gradient: Gradient { orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: wfbSaMa.pressed?"#22903A":wfbSaMa.containsMouse?"#1A7530":parent._active?"#1A6E28":"#0D3D17" }
                                GradientStop { position: 1.0; color: wfbSaMa.pressed?"#1A7830":wfbSaMa.containsMouse?"#155E26":parent._active?"#145820":"#092E11" } }
                            border.color: parent._active ? Qt.rgba(0.2,1.0,0.4,0.9) : Qt.rgba(0.2,0.85,0.4,0.4)
                            border.width: parent._active ? 2 : 1
                            ColumnLayout {
                                anchors.centerIn: parent; spacing: 1
                                QGCLabel { Layout.alignment: Qt.AlignHCenter; text: "◉  Standalone"; color: "white"; font.pointSize: ScreenTools.smallFontPointSize; font.bold: true }
                                QGCLabel { visible: parent.parent._active; Layout.alignment: Qt.AlignHCenter; text: "● active"; color: "#5AFF7A"; font.pointSize: ScreenTools.smallFontPointSize - 1 }
                            }
                            MouseArea { id: wfbSaMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    _runPanelCmd("relay wfb switch --mode standalone", "Switching to Standalone…")
                                    wfbCheckTimer.restart()
                                }
                            }
                        }

                        // Cluster
                        Rectangle {
                            Layout.fillWidth: true; height: _btnH; radius: 5
                            property bool _active: _root._wfbMode === "cluster"
                            gradient: Gradient { orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: wfbClMa.pressed?"#2264A8":wfbClMa.containsMouse?"#1A5290":parent._active?"#1A4E7A":"#0D2840" }
                                GradientStop { position: 1.0; color: wfbClMa.pressed?"#1A5494":wfbClMa.containsMouse?"#14407A":parent._active?"#15406E":"#092030" } }
                            border.color: parent._active ? Qt.rgba(0.2,0.7,1.0,0.9) : Qt.rgba(0.2,0.6,1.0,0.4)
                            border.width: parent._active ? 2 : 1
                            ColumnLayout {
                                anchors.centerIn: parent; spacing: 1
                                QGCLabel { Layout.alignment: Qt.AlignHCenter; text: "⬡  Cluster"; color: "white"; font.pointSize: ScreenTools.smallFontPointSize; font.bold: true }
                                QGCLabel { visible: parent.parent._active; Layout.alignment: Qt.AlignHCenter; text: "● active"; color: "#5AB4FF"; font.pointSize: ScreenTools.smallFontPointSize - 1 }
                            }
                            MouseArea { id: wfbClMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    _runPanelCmd("relay wfb switch --mode cluster", "Switching to Cluster…")
                                    wfbCheckTimer.restart()
                                }
                            }
                        }
                    }

                    Rectangle { Layout.fillWidth: true; height: 1; color: Qt.rgba(1,1,1,0.08) }

                    // ── Status ──────────────────────────────────────────
                    QGCLabel {
                        visible: _panelCmdActive || _panelStatus !== ""
                        text:    _panelCmdActive ? "Running…" : _panelStatus
                        color:   _panelCmdActive ? QGroundControl.globalPalette.colorOrange :
                                 _panelStatus.startsWith("✓") ? "#5AD65A" : "#FF7070"
                        font.pointSize: ScreenTools.smallFontPointSize
                        Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
        }

        // ── Left-edge resize handle (right-side only — drag left to grow) ──
        MouseArea {
            id:              leftResizeHandle
            z:               6
            visible:         _rightPanelOpen
            width:           8
            preventStealing: true
            anchors { left: parent.left; top: parent.top; topMargin: _rpHdrH + 1; bottom: parent.bottom; bottomMargin: 10 }
            hoverEnabled: true
            cursorShape:  Qt.SizeHorCursor

            property real _pressGlobalX: 0
            property real _pressW:       0

            onPressed:  (mouse) => {
                var g       = mapToItem(_root, mouse.x, mouse.y)
                _pressGlobalX = g.x
                _pressW       = _root._rpContentW
            }
            onPositionChanged: (mouse) => {
                if (!pressed) return
                var gx    = mapToItem(_root, mouse.x, mouse.y).x
                var delta = gx - _pressGlobalX
                _root._rpContentW = Math.max(_root._rpMinW, Math.min(_pressW - delta, _root.width * 0.75))
                _root._updateRpX()
            }
            onReleased: { _root._saveRpLayout() }
        }

        // ── Bottom-edge resize handle ──────────────────────────────────────
        MouseArea {
            id:              bottomResizeHandle
            z:               6
            visible:         _rightPanelOpen
            height:          8
            preventStealing: true
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 10 }
            hoverEnabled: true
            cursorShape:  Qt.SizeVerCursor

            property real _pressGlobalY: 0
            property real _pressH:       0

            onPressed:  (mouse) => {
                var g       = mapToItem(_root, mouse.x, mouse.y)
                _pressGlobalY = g.y
                _pressH       = rightPanel.height
            }
            onPositionChanged: (mouse) => {
                if (!pressed) return
                var gy   = mapToItem(_root, mouse.x, mouse.y).y
                var newH = Math.max(_root._rpMinH,
                           Math.min(_pressH + (gy - _pressGlobalY),
                                    _root.height - rightPanel.y))
                rightPanel.height = newH
            }
            onReleased: { _root._clampRpY(); _root._saveRpLayout() }
        }

        // ── Top-edge resize handle — drag up/down to move top edge ──────────
        MouseArea {
            id:              topResizeHandle
            z:               6
            visible:         _rightPanelOpen
            height:          8
            preventStealing: true
            anchors { left: parent.left; right: parent.right; top: parent.top; rightMargin: _tabW }
            hoverEnabled: true
            cursorShape:  Qt.SizeVerCursor

            property real _pressGlobalY: 0
            property real _pressH:       0
            property real _pressY:       0

            onPressed: (mouse) => {
                var g       = mapToItem(_root, mouse.x, mouse.y)
                _pressGlobalY = g.y
                _pressH       = rightPanel.height
                _pressY       = rightPanel.y
            }
            onPositionChanged: (mouse) => {
                if (!pressed) return
                var gy   = mapToItem(_root, mouse.x, mouse.y).y
                var dy   = gy - _pressGlobalY
                var newH = _pressH - dy
                var newY = _pressY + dy
                // clamp: height >= minimum
                if (newH < _root._rpMinH) {
                    newH = _root._rpMinH
                    newY = _pressY + _pressH - newH
                }
                // clamp: top edge >= screen top
                if (newY < 0) {
                    newY = 0
                    newH = _pressY + _pressH
                }
                rightPanel.y      = newY
                rightPanel.height = newH
            }
            onReleased: { _root._saveRpLayout() }
        }

        // ── Bottom-left corner resize handle (right-side only) ────────────
        Rectangle {
            id:      cornerHandle
            z:       6
            visible: _rightPanelOpen
            width:   12; height: 12
            anchors { left: parent.left; bottom: parent.bottom }
            color:   cornerMa.containsMouse ? Qt.rgba(0.3,0.6,1.0,0.5)
                                            : Qt.rgba(0.3,0.6,1.0,0.18)
            radius:  2

            QGCLabel {
                anchors.centerIn: parent
                text:           "⤡"
                color:          Qt.rgba(0.6, 0.85, 1.0, 0.9)
                font.pointSize: ScreenTools.smallFontPointSize - 1
            }

            MouseArea {
                id:           cornerMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape:  Qt.SizeBDiagCursor

                property real _pressGlobalX: 0
                property real _pressGlobalY: 0
                property real _pressW:       0
                property real _pressH:       0
                property real _pressPanelX:  0

                onPressed:  (mouse) => {
                    var g       = mapToItem(_root, mouse.x, mouse.y)
                    _pressGlobalX = g.x
                    _pressGlobalY = g.y
                    _pressW       = _root._rpContentW
                    _pressH       = rightPanel.height
                    _pressPanelX  = rightPanel.x
                }
                onPositionChanged: (mouse) => {
                    if (!pressed) return
                    var g    = mapToItem(_root, mouse.x, mouse.y)
                    var dx   = g.x - _pressGlobalX
                    var dy   = g.y - _pressGlobalY
                    var newW = Math.max(_root._rpMinW, Math.min(_pressW - dx, _root.width * 0.75))
                    var newH = Math.max(_root._rpMinH,
                               Math.min(_pressH + dy, _root.height - rightPanel.y))
                    _root._rpContentW = newW
                    rightPanel.height = newH
                    _root._updateRpX()
                }
                onReleased: { _root._saveRpLayout() }
            }
        }

    }

    // -----------------------------------------------------------------------
    // Draggable camera-switch panel — drag via header label only
    // -----------------------------------------------------------------------
    Rectangle {
        id:      cameraPanel
        z:       5
        width:   _camW
        height:  camPanelCol.implicitHeight + _pad * 2
        color:   Qt.rgba(0.04, 0.06, 0.10, 0.88)
        radius:  6
        border.color: Qt.rgba(0.3, 0.7, 1.0, 0.35); border.width: 1

        onXChanged: { _root._clamp(cameraPanel); _root._savePos() }
        onYChanged: { _root._clamp(cameraPanel); _root._savePos() }

        ColumnLayout {
            id:              camPanelCol
            anchors.left:    parent.left
            anchors.right:   parent.right
            anchors.top:     parent.top
            anchors.margins: _pad
            spacing:         _pad * 0.7

            // Drag handle
            Item {
                Layout.fillWidth: true
                height: ScreenTools.defaultFontPixelHeight * 1.6
                QGCLabel {
                    anchors.centerIn: parent
                    text: "⋮⋮  Camera View  ⋮⋮"
                    font.pointSize: ScreenTools.smallFontPointSize; font.bold: true; color: "#8BBFFF"
                }
                MouseArea {
                    anchors.fill: parent
                    drag.target: cameraPanel; drag.axis: Drag.XAndYAxis
                    drag.minimumX: 0; drag.minimumY: 0
                    drag.maximumX: Math.max(0, _root.width  - cameraPanel.width)
                    drag.maximumY: Math.max(0, _root.height - cameraPanel.height)
                    cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: Qt.rgba(0.3,0.6,1.0,0.3) }

            // Row 1: Front / Bottom
            RowLayout { Layout.fillWidth: true; spacing: _pad * 0.8
                Rectangle { Layout.fillWidth: true; height: _camBtnH; radius: 4
                    gradient: Gradient { orientation: Gradient.Horizontal
                        GradientStop { position:0.0; color:fMa.pressed?"#1DC5D8":fMa.containsMouse?"#17A0B0":"#0C6070" }
                        GradientStop { position:1.0; color:fMa.pressed?"#15A5B5":fMa.containsMouse?"#0E8090":"#084858" } }
                    border.color: Qt.rgba(0.1,0.8,0.9,0.4); border.width: 1
                    QGCLabel { anchors.centerIn:parent; text:"F-SW"; color:"white"; font.pointSize:ScreenTools.smallFontPointSize; font.bold:true }
                    MouseArea { id:fMa; anchors.fill:parent; hoverEnabled:true; cursorShape:Qt.PointingHandCursor
                        onClicked: PXLABSRunner.run("companion front-switch") } }
                Rectangle { Layout.fillWidth: true; height: _camBtnH; radius: 4
                    gradient: Gradient { orientation: Gradient.Horizontal
                        GradientStop { position:0.0; color:bMa.pressed?"#1DC5D8":bMa.containsMouse?"#17A0B0":"#0C6070" }
                        GradientStop { position:1.0; color:bMa.pressed?"#15A5B5":bMa.containsMouse?"#0E8090":"#084858" } }
                    border.color: Qt.rgba(0.1,0.8,0.9,0.4); border.width: 1
                    QGCLabel { anchors.centerIn:parent; text:"B-SW"; color:"white"; font.pointSize:ScreenTools.smallFontPointSize; font.bold:true }
                    MouseArea { id:bMa; anchors.fill:parent; hoverEnabled:true; cursorShape:Qt.PointingHandCursor
                        onClicked: PXLABSRunner.run("companion bottom-switch") } }
            }

            // Row 2: Split
            RowLayout { Layout.fillWidth: true; spacing: _pad * 0.8
                Rectangle { Layout.fillWidth: true; height: _camBtnH; radius: 4
                    gradient: Gradient { orientation: Gradient.Horizontal
                        GradientStop { position:0.0; color:sfbMa.pressed?"#22B8A0":sfbMa.containsMouse?"#1A9880":"#0E6050" }
                        GradientStop { position:1.0; color:sfbMa.pressed?"#1A9880":sfbMa.containsMouse?"#147860":"#0A4840" } }
                    border.color: Qt.rgba(0.1,0.9,0.7,0.4); border.width: 1
                    QGCLabel { anchors.centerIn:parent; text:"F/B-SW"; color:"white"; font.pointSize:ScreenTools.smallFontPointSize; font.bold:true }
                    MouseArea { id:sfbMa; anchors.fill:parent; hoverEnabled:true; cursorShape:Qt.PointingHandCursor
                        onClicked: PXLABSRunner.run("companion split-front-bottom") } }
                Rectangle { Layout.fillWidth: true; height: _camBtnH; radius: 4
                    gradient: Gradient { orientation: Gradient.Horizontal
                        GradientStop { position:0.0; color:sbfMa.pressed?"#22B8A0":sbfMa.containsMouse?"#1A9880":"#0E6050" }
                        GradientStop { position:1.0; color:sbfMa.pressed?"#1A9880":sbfMa.containsMouse?"#147860":"#0A4840" } }
                    border.color: Qt.rgba(0.1,0.9,0.7,0.4); border.width: 1
                    QGCLabel { anchors.centerIn:parent; text:"B/F-SW"; color:"white"; font.pointSize:ScreenTools.smallFontPointSize; font.bold:true }
                    MouseArea { id:sbfMa; anchors.fill:parent; hoverEnabled:true; cursorShape:Qt.PointingHandCursor
                        onClicked: PXLABSRunner.run("companion split-bottom-front") } }
            }
        }
    }

    // -----------------------------------------------------------------------
    Component.onCompleted: {
        Qt.callLater(function() {
            _restoreRpLayout()
            _restorePos()
        })
    }
    onWidthChanged:  { _clamp(cameraPanel); _savePos(); _updateRpX() }
    onHeightChanged: { _clamp(cameraPanel); _savePos(); _clampRpY() }
}
