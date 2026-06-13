// PXLABS integration — additive file, do not modify existing QGC code
// CompanionControl.qml: Camera, Capture, Record, System, Services for Vind-Roz.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls
import QGroundControl.ScreenTools
import QGroundControl.Palette
import QGroundControl.PXLABS

SettingsPage {
    id: root

    property bool   _busy:        false   // own commands only — not global runner state
    property string _swap:        swapCheck.checked ? " --swap" : ""
    property string _bgRetryArgs: ""      // queued args while waiting for bg abort to settle

    // After aborting a background fetch, retry the user command once the runner is free
    Timer {
        id:       bgRetryTimer
        interval: 400
        repeat:   false
        onTriggered: {
            if (PXLABSRunner.running) return   // still busy — give up silently
            outputArea.text = ""
            root._busy = true
            PXLABSRunner.run(root._bgRetryArgs)
        }
    }

    // Services — dynamic list populated by refresh
    property bool   _svcRefreshActive: false
    property string _svcLastOutput:    ""
    property var    _svcNames: [
        "mavlink.router.service", "microxrce-agent.service",
        "rc_control_node.service", "vision_streaming.service",
        "tfmini.service", "ros2_px4_translation_node.service",
        "block-traffic.service", "wifibroadcast@drone.service",
        "system_files_sync.timer"
    ]

    // Camera resolution/fps/format — dynamic lists populated by camera-query
    property bool   _camQueryActive: false
    property string _camLastOutput:  ""
    property var    _camFmtMap:      ({})   // format -> { order: [resolutions], fps: {resolution: [fps]} }
    property var    _camFormatList:  ["MJPG", "UYVY"]
    property string _camDetectedFmt: ""
    property string _camDetectedRes: ""
    property string _camDetectedFps: ""

    readonly property var _camResOptions: {
        var fmt = _camFmtMap[fmtCombo.currentText]
        return (fmt && fmt.order.length > 0) ? fmt.order
                                              : ["1920x1080", "1280x720", "960x540", "640x480", "320x240"]
    }
    readonly property var _camFpsOptions: {
        var fmt = _camFmtMap[fmtCombo.currentText]
        var fps = fmt ? fmt.fps[resCombo.currentText] : null
        return (fps && fps.length > 0) ? fps : ["60", "30", "15", "10", "5"]
    }

    function _run(args) {
        if (PXLABSRunner.running) {
            if (QGroundControl.loadGlobalSetting("pxlabs_bg_active", "0") === "1") {
                // Background poll is running — abort it and retry user command automatically
                _bgRetryArgs = args
                PXLABSRunner.abort()
                bgRetryTimer.start()
            } else {
                outputArea.text = qsTr("⚠ Runner busy — please retry in a moment.")
            }
            return
        }
        outputArea.text = ""
        _busy = true
        PXLABSRunner.run(args)
    }

    function _resolvedSvc() {
        const t = customSvcField.text.trim()
        return t.length > 0 ? t : svcCombo.currentText
    }

    // Parse `vision_config_manager list-details` output into a format/resolution/fps map
    // plus the camera's currently-active format/resolution/fps.
    function _parseCameraQuery(text) {
        var curFmtMatch = text.match(/Pixel Format\s*:\s*'(\w+)'/)
        var curResMatch = text.match(/Width\/Height\s*:\s*(\d+)\/(\d+)/)
        var curFpsMatch = text.match(/Frames per second:\s*([\d.]+)/)

        var lines = text.split('\n')
        var map = {}
        var curFmt = null, curRes = null, inFormats = false

        for (var i = 0; i < lines.length; i++) {
            var line = lines[i]
            if (!inFormats) {
                if (line.indexOf("Supported Formats") >= 0) inFormats = true
                continue
            }
            var fm = line.match(/^\s*\[\d+\]:\s*'(\w+)'/)
            if (fm) {
                curFmt = fm[1]
                if (!map[curFmt]) map[curFmt] = { order: [], fps: {} }
                curRes = null
                continue
            }
            var sm = line.match(/Size:\s*Discrete\s*(\d+x\d+)/)
            if (sm && curFmt) {
                curRes = sm[1]
                if (map[curFmt].order.indexOf(curRes) < 0) map[curFmt].order.push(curRes)
                if (!map[curFmt].fps[curRes]) map[curFmt].fps[curRes] = []
                continue
            }
            var fpm = line.match(/\(([\d.]+)\s*fps\)/)
            if (fpm && curFmt && curRes) {
                var v = parseFloat(fpm[1]).toString()
                if (map[curFmt].fps[curRes].indexOf(v) < 0) map[curFmt].fps[curRes].push(v)
            }
        }

        return {
            map:    map,
            curFmt: curFmtMatch ? curFmtMatch[1] : "",
            curRes: curResMatch ? (curResMatch[1] + "x" + curResMatch[2]) : "",
            curFps: curFpsMatch ? parseFloat(curFpsMatch[1]).toString() : ""
        }
    }

    // Populate the Resolution/FPS/Format dropdowns from a camera-query result,
    // pre-selecting the camera's currently-active values.
    function _applyCameraQuery(text) {
        var parsed = _parseCameraQuery(text)
        var fmts = Object.keys(parsed.map)
        _camFmtMap      = parsed.map
        _camFormatList  = fmts.length > 0 ? fmts : ["MJPG", "UYVY"]
        _camDetectedFmt = parsed.curFmt
        _camDetectedRes = parsed.curRes
        _camDetectedFps = parsed.curFps

        var fi = _camFormatList.indexOf(_camDetectedFmt)
        fmtCombo.currentIndex = fi >= 0 ? fi : 0

        Qt.callLater(function() {
            var ri = _camResOptions.indexOf(_camDetectedRes)
            resCombo.currentIndex = ri >= 0 ? ri : 0

            Qt.callLater(function() {
                var fpi = _camFpsOptions.indexOf(_camDetectedFps)
                fpsCombo.currentIndex = fpi >= 0 ? fpi : 0
            })
        })
    }

    Connections {
        target: PXLABSRunner
        function onOutputReady(text) {
            if (!_busy) return
            outputArea.text = text
            if (_svcRefreshActive) _svcLastOutput = text
            if (_camQueryActive)   _camLastOutput = text
        }
        function onCommandFinished(exitCode) {
            if (!_busy) return
            _busy = false
            if (_svcRefreshActive) {
                _svcRefreshActive = false
                var lines = _svcLastOutput.split('\n')
                var names = []
                for (var i = 0; i < lines.length; i++) {
                    var parts = lines[i].trim().split('|')
                    if (parts.length >= 2 && parts[0].length > 0) names.push(parts[0])
                }
                if (names.length > 0) _svcNames = names
            }
            if (_camQueryActive) {
                _camQueryActive = false
                if (exitCode === 0) _applyCameraQuery(_camLastOutput)
            }
            if (exitCode !== 0) outputArea.text += qsTr("\n[Exit code: %1]").arg(exitCode)
        }
        function onCommandFailed(errorText) {
            if (!_busy) return
            _busy = false
            _svcRefreshActive = false
            _camQueryActive   = false
            outputArea.text = qsTr("ERROR: ") + errorText
        }
    }

    // -----------------------------------------------------------------------
    // Camera Control
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Camera Switch")

        QGCCheckBoxSlider {
            id:               swapCheck
            Layout.fillWidth: true
            text:             qsTr("Swap camera mapping (front ↔ bottom device)")
            checked:          false
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:      qsTr("Front Camera")
                enabled:   !_busy
                onClicked: _run("companion front-switch" + _swap)
            }

            QGCButton {
                text:      qsTr("Bottom Camera")
                enabled:   !_busy
                onClicked: _run("companion bottom-switch" + _swap)
            }

            QGCButton {
                text:      qsTr("Split: Front+Bottom")
                enabled:   !_busy
                onClicked: _run("companion split-front-bottom" + _swap)
            }

            QGCButton {
                text:      qsTr("Split: Bottom+Front")
                enabled:   !_busy
                onClicked: _run("companion split-bottom-front" + _swap)
            }
        }
    }


    // -----------------------------------------------------------------------
    // Camera Device (Advanced)
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Camera Device (Advanced)")

        // ── Device + switch row ──────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("Device:") }

            QGCComboBox {
                id:    deviceCombo
                model: ["/dev/video0", "/dev/video2", "/dev/video3"]
            }

            QGCButton {
                text:      qsTr("Query Details")
                enabled:   !_busy
                onClicked: { _camQueryActive = true; _run("companion camera-query --device " + deviceCombo.currentText) }
            }

            QGCLabel {
                text:           qsTr("(Query Details to populate Resolution/FPS/Format)")
                color:          QGroundControl.globalPalette.colorGrey
                font.pointSize: ScreenTools.smallFontPointSize
            }
        }

        // ── Resolution / FPS / Format params row ────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("Format:") }
            QGCComboBox {
                id:    fmtCombo
                model: _camFormatList
            }

            QGCLabel { text: qsTr("Resolution:") }
            QGCComboBox {
                id:    resCombo
                model: _camResOptions
            }

            QGCLabel { text: qsTr("FPS:") }
            QGCComboBox {
                id:    fpsCombo
                model: _camFpsOptions
            }

            QGCButton {
                text:      qsTr("Apply")
                enabled:   !_busy
                onClicked: _run("companion camera-params --device " + deviceCombo.currentText
                                + " --resolution " + resCombo.currentText
                                + " --fps "        + fpsCombo.currentText
                                + " --format "     + fmtCombo.currentText)
            }
        }
    }

    // -----------------------------------------------------------------------
    // System
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Companion System")

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:      qsTr("SSH Terminal")
                enabled:   !_busy
                onClicked: _run("companion ssh-terminal")
            }

            QGCButton {
                text:      qsTr("Reboot")
                enabled:   !_busy
                onClicked: {
                    rebootConfirm.visible = true
                }
            }

            QGCButton {
                text:      qsTr("Shutdown")
                enabled:   !_busy
                onClicked: {
                    shutdownConfirm.visible = true
                }
            }
        }

        // Reboot confirmation
        ColumnLayout {
            id:      rebootConfirm
            visible: false
            Layout.fillWidth: true

            QGCLabel {
                text:    qsTr("Confirm reboot companion computer?")
                color:   QGroundControl.globalPalette.colorOrange
            }
            RowLayout {
                spacing: ScreenTools.defaultFontPixelWidth
                QGCButton {
                    text:      qsTr("Yes — Reboot")
                    onClicked: { rebootConfirm.visible = false; _run("companion reboot") }
                }
                QGCButton {
                    text:      qsTr("Cancel")
                    onClicked: rebootConfirm.visible = false
                }
            }
        }

        // Shutdown confirmation
        ColumnLayout {
            id:      shutdownConfirm
            visible: false
            Layout.fillWidth: true

            QGCLabel {
                text:    qsTr("Confirm shutdown companion computer?")
                color:   QGroundControl.globalPalette.colorRed
            }
            RowLayout {
                spacing: ScreenTools.defaultFontPixelWidth
                QGCButton {
                    text:      qsTr("Yes — Shutdown")
                    onClicked: { shutdownConfirm.visible = false; _run("companion shutdown") }
                }
                QGCButton {
                    text:      qsTr("Cancel")
                    onClicked: shutdownConfirm.visible = false
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Services
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Companion Services")

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:      qsTr("Refresh Status")
                enabled:   !_busy
                onClicked: { _svcRefreshActive = true; _run("services refresh --target companion") }
            }

            QGCLabel {
                text:           qsTr("(list updates after refresh)")
                color:          QGroundControl.globalPalette.colorGrey
                font.pointSize: ScreenTools.smallFontPointSize
            }
        }

        // Service selector — populated from refresh output
        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("Service:") }

            QGCComboBox {
                id:               svcCombo
                Layout.fillWidth: true
                model:            _svcNames
            }
        }

        // Custom override — type any service name not in the list
        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("Custom:") }

            QGCTextField {
                id:               customSvcField
                Layout.fillWidth: true
                placeholderText:  qsTr("or type any service name…")
            }
        }

        // Action buttons
        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:      qsTr("Start")
                enabled:   !_busy
                onClicked: _run("services start --target companion --service " + _resolvedSvc())
            }

            QGCButton {
                text:      qsTr("Stop")
                enabled:   !_busy
                onClicked: _run("services stop --target companion --service " + _resolvedSvc())
            }

            QGCButton {
                text:      qsTr("Restart")
                enabled:   !_busy
                onClicked: _run("services restart --target companion --service " + _resolvedSvc())
            }

            QGCButton {
                text:      qsTr("Enable")
                enabled:   !_busy
                onClicked: _run("services enable --target companion --service " + _resolvedSvc())
            }

            QGCButton {
                text:      qsTr("Disable")
                enabled:   !_busy
                onClicked: _run("services disable --target companion --service " + _resolvedSvc())
            }
        }
    }

    // -----------------------------------------------------------------------
    // Abort + Status row
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Runner")

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:      qsTr("Abort")
                enabled:   _busy
                onClicked: PXLABSRunner.abort()
            }

            QGCLabel {
                text:  _busy ? qsTr("Running…") : qsTr("Idle")
                color: _busy ? QGroundControl.globalPalette.colorOrange : QGroundControl.globalPalette.text
            }

            Item { Layout.fillWidth: true }

            QGCButton {
                text:      qsTr("Clear Output")
                onClicked: outputArea.text = ""
            }
        }
    }

    // -----------------------------------------------------------------------
    // Output
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Output")

        TextArea {
            id:               outputArea
            Layout.fillWidth: true
            height:           ScreenTools.defaultFontPixelHeight * 26
            readOnly:         true
            font.family:      "Courier New"
            font.pointSize:   ScreenTools.smallFontPointSize
            wrapMode:         TextArea.Wrap
            color:            "#D8D8D8"
            text:             qsTr("(output will appear here)")
            background: Rectangle {
                color:        QGroundControl.globalPalette.windowShade
                radius:       3
                border.color: QGroundControl.globalPalette.button
                border.width: 1
            }
        }
    }
}
