/****************************************************************************
 *
 * PXLABS G-Control — FlyView custom layer
 * - Left-edge  "Transmission Mode" panel (dish antenna, WFB standalone/cluster)
 * - Right-edge "System Control" panel (Companion + Relay power/SSH + WFB mode)
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
    property bool   _panelInitDone:      false
    property bool   _rightPanelOpen:     false
    // WFB mode: "standalone" | "cluster" | ""
    property string _wfbMode:           QGroundControl.loadGlobalSetting("pxlabs_wfb_mode", "")
    property bool   _wfbStatusFetch:    false   // true while querying relay wfb status

    // Panel status (SSH / other panel commands)
    property string _panelStatus:        ""
    property bool   _panelCmdActive:     false

    readonly property real _pad:      ScreenTools.defaultFontPixelWidth
    readonly property real _rpWidth:  ScreenTools.defaultFontPixelWidth * 23
    readonly property real _tabW:     ScreenTools.defaultFontPixelWidth * 2.2
    readonly property real _btnH:     ScreenTools.defaultFontPixelHeight * 2.1
    readonly property real _sshBtnH:  ScreenTools.defaultFontPixelHeight * 1.85

    // Camera panel
    readonly property real _camW:     ScreenTools.defaultFontPixelWidth  * 22
    readonly property real _camBtnH:  ScreenTools.defaultFontPixelHeight * 2.4

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
    // Helpers
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

    function _confirm(title, msg, cmd) {
        mainWindow.showMessageDialog(title, msg, Dialog.Yes | Dialog.No,
                                     function() { PXLABSRunner.run(cmd) })
    }

    function _runPanelCmd(args, statusMsg) {
        if (PXLABSRunner.running) return
        _panelStatus = statusMsg
        _panelCmdActive = true
        PXLABSRunner.run(args)
    }

    function _checkWfbMode() {
        if (PXLABSRunner.running) return
        _wfbStatusFetch = true
        PXLABSRunner.run("relay wfb refresh")   // outputs SA:active/inactive, CA:active/inactive
    }

    // -----------------------------------------------------------------------
    // Runner output routing
    // -----------------------------------------------------------------------
    Connections {
        target: PXLABSRunner

        function onOutputReady(text) {
            if (_wfbStatusFetch) {
                // relay wfb refresh outputs: SA:<status>, CA:<status>
                // SA=standalone service, CA=cluster service
                var saMatch = text.match(/^SA:(\S+)/m)
                var caMatch = text.match(/^CA:(\S+)/m)
                if (saMatch && caMatch) {
                    var sa = saMatch[1]
                    var ca = caMatch[1]
                    var newMode = ""
                    if (sa === "active" && ca !== "active")       newMode = "standalone"
                    else if (ca === "active" && sa !== "active")  newMode = "cluster"
                    else if (sa === "active" && ca === "active")  newMode = "standalone"  // both → prefer standalone
                    if (newMode !== "") {
                        _root._wfbMode = newMode
                        QGroundControl.saveGlobalSetting("pxlabs_wfb_mode", newMode)
                    }
                }
                return
            }
            if (_panelCmdActive) {
                // Show SSH open message or other command output in panel status
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
                if (exitCode !== 0)
                    _panelStatus = "✗ Failed (exit " + exitCode + ")"
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
    // Right-edge "System Control" expandable panel
    // -----------------------------------------------------------------------
    Rectangle {
        id:      rightPanel
        anchors.right:        parent.right
        anchors.top:          parent.top
        anchors.bottom:       parent.bottom
        anchors.topMargin:    _toolInsets.topEdgeRightInset + ScreenTools.defaultFontPixelHeight * 7
        anchors.bottomMargin: _toolInsets.bottomEdgeRightInset

        width:  _rightPanelOpen ? _rpWidth + _tabW : _tabW
        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        color:        Qt.rgba(0.04, 0.06, 0.10, 0.93)
        border.color: Qt.rgba(0.3, 0.6, 1.0, 0.18)
        border.width: 1

        // ---- pull tab ----
        Rectangle {
            id:     pullTab
            width:  _tabW
            height: ScreenTools.defaultFontPixelHeight * 6.5
            radius: 3
            anchors.right:      parent.right
            anchors.top:        parent.top
            anchors.topMargin:  ScreenTools.defaultFontPixelHeight * 2
            color: tabMa.pressed ? Qt.rgba(0.3,0.6,1.0,0.28) :
                   tabMa.containsMouse ? Qt.rgba(0.3,0.6,1.0,0.16) : Qt.rgba(1,1,1,0.06)
            border.color: Qt.rgba(0.3,0.6,1.0,0.35); border.width: 1

            Column {
                anchors.centerIn: parent
                spacing: 2

                // WFB mode glyph — visible when panel is closed
                QGCLabel {
                    visible:            !_rightPanelOpen
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

        // ---- content ----
        Item {
            anchors.left:   parent.left
            anchors.right:  pullTab.left
            anchors.top:    parent.top
            anchors.bottom: parent.bottom
            visible:        _rightPanelOpen
            clip:           true

            Flickable {
                anchors.fill: parent
                contentHeight: panelCol.implicitHeight + _pad * 2
                contentWidth:  width
                flickableDirection: Flickable.VerticalFlick
                clip: true

                ColumnLayout {
                    id:              panelCol
                    width:           parent.width
                    anchors.top:     parent.top
                    anchors.left:    parent.left
                    anchors.right:   parent.right
                    anchors.margins: _pad * 0.9
                    spacing:         _pad * 0.5

                    // ── Header ─────────────────────────────────
                    QGCLabel {
                        text: "⚡  System Control"
                        font.bold: true; font.pointSize: ScreenTools.defaultFontPointSize + 0.5
                        color: "#8BBFFF"; Layout.fillWidth: true
                    }
                    Rectangle { Layout.fillWidth: true; height: 1; color: Qt.rgba(0.3,0.6,1.0,0.35) }

                    // ── Companion ──────────────────────────────
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

                    // ── Relay Station ──────────────────────────
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

                    // ── WFB Mode ───────────────────────────────
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

                    // ── Status ─────────────────────────────────
                    QGCLabel {
                        visible: PXLABSRunner.running || _panelStatus !== ""
                        text:    PXLABSRunner.running ? "⏳  Running…" : _panelStatus
                        color:   PXLABSRunner.running ? QGroundControl.globalPalette.colorOrange :
                                 _panelStatus.startsWith("✓") ? "#5AD65A" : "#FF7070"
                        font.pointSize: ScreenTools.smallFontPointSize
                        Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                    }
                }
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
    Component.onCompleted: { Qt.callLater(_restorePos) }
    onWidthChanged:  { _clamp(cameraPanel); _savePos() }
    onHeightChanged: { _clamp(cameraPanel); _savePos() }
}
