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

    property bool _busy: false   // own commands only — bus state is global

    // Camera rows (Set Primary / Set PiP / Rename) only exist once the
    // inventory is loaded — fetch it on page open instead of waiting for
    // a manual Refresh List click.
    Component.onCompleted: Qt.callLater(_refreshCameras)

    // Services — dynamic list populated by refresh
    property var    _svcNames: [
        "mavlink.router.service", "microxrce-agent.service",
        "rc_control_node.service", "vision_streaming.service",
        "tfmini.service", "ros2_px4_translation_node.service",
        "block-traffic.service", "wifibroadcast@drone.service",
        "system_files_sync.timer"
    ]

    // Multi-camera inventory (vision_config_manager v2 via camera-list JSON)
    property var    _cameras:         []    // [{id, dev, hw_name, alias, streamable, formats, role_lock}]
    property string _activePrimary:   ""    // stable id (or raw dev) from `active`
    property string _activeSecondary: ""
    property string _renameId:        ""    // camera id being renamed ("" = editor hidden)

    // Camera resolution/fps/format — dynamic lists populated by camera-query
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

    // Dispatch a facade request; route its correlated output back to this panel.
    function _dispatch(req) {
        _busy = true
        outputArea.text = ""
        req.outputChanged.connect(function() { outputArea.text = req.output })
        req.succeeded.connect(function(exitCode) { _busy = false })
        req.failed.connect(function(errorText) {
            _busy = false
            // req.output already carries the real captured stdout/stderr (e.g. the
            // CLI's "Error: ..." line) — don't let the generic "exit 1" message
            // stomp it, or the actual cause is invisible until someone re-runs by hand.
            var body = req.output ? req.output.trim() : ""
            outputArea.text = (body.length > 0 ? body + "\n\n" : "") + qsTr("ERROR: ") + errorText
        })
        return req
    }

    // Refresh the services list, then repopulate the selector from the output.
    function _refreshServices() {
        var req = _dispatch(Pxlabs.companion.servicesRefresh())
        req.succeeded.connect(function() {
            var lines = req.output.split('\n')
            var names = []
            for (var i = 0; i < lines.length; i++) {
                var parts = lines[i].trim().split('|')
                if (parts.length >= 2 && parts[0].length > 0) names.push(parts[0])
            }
            if (names.length > 0) _svcNames = names
        })
    }

    // Query the camera, then populate the resolution/fps/format dropdowns on success.
    function _cameraQuery(device) {
        var req = _dispatch(Pxlabs.companion.cameraQuery(device))
        req.succeeded.connect(function() { _applyCameraQuery(req.output) })
    }

    // -----------------------------------------------------------------------
    // Multi-camera helpers (camera-list / camera-apply / camera-set-alias)
    // -----------------------------------------------------------------------
    function _camName(c) {
        return (c.alias && c.alias.length > 0) ? c.alias : (c.hw_name || c.dev || c.id)
    }

    // `active` values may be a stable id or a raw /dev/videoN — match either.
    function _camIsActive(c, key) {
        return key.length > 0 && (key === c.id || key === c.dev)
    }

    function _activeSummary() {
        var p = "", s = ""
        for (var i = 0; i < _cameras.length; i++) {
            if (_camIsActive(_cameras[i], _activePrimary))   p = _camName(_cameras[i])
            if (_camIsActive(_cameras[i], _activeSecondary)) s = _camName(_cameras[i])
        }
        if (p.length === 0) return qsTr("(active camera unknown — refresh list)")
        return qsTr("Active: ") + p + (s.length > 0 ? " + " + s + qsTr(" PiP") : "")
    }

    function _refreshCameras() {
        var req = _dispatch(Pxlabs.companion.cameraList(false, showAllCheck.checked))
        req.succeeded.connect(function() {
            // Output can carry SSH/sudo noise around the JSON — extract the object.
            var t = req.output
            var s = t.indexOf("{"), e = t.lastIndexOf("}")
            if (s < 0 || e <= s) return
            try {
                var obj = JSON.parse(t.substring(s, e + 1))
                _cameras         = obj.cameras || []
                _activePrimary   = (obj.active && obj.active.primary)   ? obj.active.primary   : ""
                _activeSecondary = (obj.active && obj.active.secondary) ? obj.active.secondary : ""
                // Auto-cascade the Advanced Format/Res/FPS dropdowns from the
                // selected device so they never show unsupported fallback values.
                if (_cameras.length > 0)
                    Qt.callLater(function() { _cameraQuery(_deviceKey()) })
            } catch (err) {
                outputArea.text += qsTr("\n(camera list JSON parse failed)")
            }
        })
    }

    function _applyCamera(primaryKey, secondaryKey) {
        var req = _dispatch(Pxlabs.companion.applyCamera(primaryKey, secondaryKey || ""))
        req.succeeded.connect(function() { _refreshCameras() })
    }

    // Advanced section: id of the selected camera (falls back to raw dev text
    // when the inventory hasn't been fetched — v2 accepts either).
    function _deviceKey() {
        if (_cameras.length > 0 && deviceCombo.currentIndex >= 0
                && deviceCombo.currentIndex < _cameras.length) {
            var c = _cameras[deviceCombo.currentIndex]
            return c.id || c.dev
        }
        return deviceCombo.currentText
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

    // -----------------------------------------------------------------------
    // Camera Control
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Cameras")

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:      qsTr("Refresh List")
                enabled:   !_busy
                onClicked: _refreshCameras()
            }

            QGCLabel {
                Layout.fillWidth: true
                text:  _activeSummary()
                color: QGroundControl.globalPalette.colorGrey
                elide: Text.ElideRight
            }
        }

        QGCCheckBoxSlider {
            id:               showAllCheck
            Layout.fillWidth: true
            text:             qsTr("Show all camera nodes (incl. depth/IR — cannot stream)")
            checked:          false
            onClicked:        _refreshCameras()
        }

        // One row per streamable camera: ● primary, ◪ secondary (PiP), ⚠ role_lock
        Repeater {
            model: _cameras

            delegate: RowLayout {
                Layout.fillWidth: true
                spacing: ScreenTools.defaultFontPixelWidth

                property var    cam:       modelData
                property string camKey:    cam.id || cam.dev || ""
                property bool   canStream: cam.streamable === true
                property bool   isPri:     _camIsActive(cam, _activePrimary)
                property bool   isSec:     _camIsActive(cam, _activeSecondary)

                QGCLabel {
                    Layout.fillWidth: true
                    text: (isPri ? "● " : isSec ? "◪ " : "") + _camName(cam)
                          + " — " + (cam.hw_name || "?") + " (" + (cam.dev || "?") + ")"
                          + (cam.role_lock ? qsTr("  ⚠ reserved: ") + cam.role_lock : "")
                          + (canStream ? "" : qsTr("  — cannot stream: ")
                                              + Object.keys(cam.formats || {}).join("/"))
                    color: !canStream ? QGroundControl.globalPalette.colorGrey
                         : isPri ? QGroundControl.globalPalette.colorGreen
                         : cam.role_lock ? QGroundControl.globalPalette.colorOrange
                         : QGroundControl.globalPalette.text
                    elide: Text.ElideRight
                }

                QGCButton {
                    text:      qsTr("Set Primary")
                    enabled:   !_busy && canStream && !isPri && camKey.length > 0
                    // Keep the current PiP unless this camera is it
                    onClicked: _applyCamera(camKey,
                                   (!isSec && _activeSecondary.length > 0) ? _activeSecondary : "")
                }

                QGCButton {
                    text:      isSec ? qsTr("Remove PiP") : qsTr("Set PiP")
                    enabled:   !_busy && canStream && !isPri && _activePrimary.length > 0 && camKey.length > 0
                    onClicked: isSec ? _applyCamera(_activePrimary, "")
                                     : _applyCamera(_activePrimary, camKey)
                }

                QGCButton {
                    text:      qsTr("Rename…")
                    enabled:   !_busy && cam.id !== undefined && cam.id !== null
                    onClicked: { _renameId = cam.id; renameField.text = cam.alias || "" }
                }
            }
        }

        // Inline alias editor (opens via Rename…)
        RowLayout {
            visible: _renameId.length > 0
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("Alias:") }

            QGCTextField {
                id:               renameField
                Layout.fillWidth: true
                maximumLength:    32
                placeholderText:  qsTr("1-32 chars: letters/digits/space _ . -")
            }

            QGCButton {
                text:    qsTr("Save")
                enabled: !_busy && renameField.text.trim().length > 0
                onClicked: {
                    var req = _dispatch(Pxlabs.companion.setCameraAlias(_renameId, renameField.text.trim()))
                    req.succeeded.connect(function() { _renameId = ""; _refreshCameras() })
                }
            }

            QGCButton {
                text:      qsTr("Cancel")
                onClicked: _renameId = ""
            }
        }

        QGCLabel {
            visible:        _cameras.length === 0
            text:           qsTr("(Refresh List to load cameras from the companion)")
            color:          QGroundControl.globalPalette.colorGrey
            font.pointSize: ScreenTools.smallFontPointSize
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
                id: deviceCombo
                Layout.preferredWidth: ScreenTools.defaultFontPixelWidth * 26
                // Inventory-driven once fetched; raw dev fallback until then
                model: _cameras.length > 0
                       ? _cameras.map(function(c) { return _camName(c) + " (" + (c.dev || "?") + ")" })
                       : ["/dev/video0", "/dev/video2", "/dev/video3"]
                // Re-cascade Format/Res/FPS for the newly selected device
                onActivated: _cameraQuery(_deviceKey())
            }

            QGCButton {
                text:      qsTr("Query Details")
                enabled:   !_busy
                onClicked: _cameraQuery(_deviceKey())
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
                // Only enabled once the inventory is loaded and a real camera is
                // selected — otherwise _deviceKey() falls through to raw combo
                // text, which can be a stale /dev/videoN the companion no longer
                // owns (see camera-outage postmortem).
                enabled:   !_busy && _cameras.length > 0
                           && deviceCombo.currentIndex >= 0 && deviceCombo.currentIndex < _cameras.length
                onClicked: _dispatch(Pxlabs.companion.setCamParams(_deviceKey(), resCombo.currentText, fpsCombo.currentText, fmtCombo.currentText))
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
                onClicked: _dispatch(Pxlabs.companion.sshTerminal())
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
                    onClicked: { rebootConfirm.visible = false; _dispatch(Pxlabs.companion.reboot()) }
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
                    onClicked: { shutdownConfirm.visible = false; _dispatch(Pxlabs.companion.shutdown()) }
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
                onClicked: _refreshServices()
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
                onClicked: _dispatch(Pxlabs.companion.serviceStart(_resolvedSvc()))
            }

            QGCButton {
                text:      qsTr("Stop")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.companion.serviceStop(_resolvedSvc()))
            }

            QGCButton {
                text:      qsTr("Restart")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.companion.serviceRestart(_resolvedSvc()))
            }

            QGCButton {
                text:      qsTr("Enable")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.companion.serviceEnable(_resolvedSvc()))
            }

            QGCButton {
                text:      qsTr("Disable")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.companion.serviceDisable(_resolvedSvc()))
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
