// PXLABS integration — additive file, do not modify existing QGC code
// RelayControl.qml: WFB mode, NICs, system, services for Vind-Rly relay station.

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

    property bool   _busy:      false   // own commands only — bus state is global

    // Services — dynamic list populated by refresh
    property var    _svcNames: [
        "wifibroadcast@gs.service", "wifibroadcast-cluster@gs.service",
        "mavlink.router.service", "ssh-tunnel-to-companion.service",
        "relay_files_sync.timer", "mediamtx.service", "isc-dhcp-server.service"
    ]

    function _resolvedSvc() {
        const t = customRelaySvcField.text.trim()
        return t.length > 0 ? t : relaySvcCombo.currentText
    }

    // Parse SA/CA lines from wfb output and persist so the fly view glyph stays in sync.
    function _parseSaCa(text) {
        var saMatch = text.match(/^SA:(\S+)/m)
        var caMatch = text.match(/^CA:(\S+)/m)
        if (saMatch && caMatch) {
            var sa = saMatch[1]; var ca = caMatch[1]
            var mode = (sa === "active" && ca !== "active") ? "standalone" :
                       (ca === "active" && sa !== "active") ? "cluster"    : ""
            if (mode !== "") QGroundControl.saveGlobalSetting("pxlabs_wfb_mode", mode)
        }
    }

    // Dispatch a facade request; route its correlated output back to this panel.
    function _dispatch(req) {
        _busy = true
        outputArea.text = ""
        req.outputChanged.connect(function() { outputArea.text = req.output; _parseSaCa(req.output) })
        req.succeeded.connect(function(exitCode) { _busy = false })
        req.failed.connect(function(errorText)   { _busy = false; outputArea.text = qsTr("ERROR: ") + errorText })
        return req
    }

    // Refresh the services list, then repopulate the selector from the output.
    function _refreshServices() {
        var req = _dispatch(Pxlabs.relay.servicesRefresh())
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

    // Switch WFB mode, then refresh once it settles (regardless of outcome).
    function _switchWfb(mode) {
        var req = _dispatch(Pxlabs.relay.wfbSwitch(mode))
        req.completeChanged.connect(function() {
            if (req.complete) Qt.callLater(function() { _dispatch(Pxlabs.relay.wfbRefresh()) })
        })
    }

    // -----------------------------------------------------------------------
    // WFB Mode
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("WFB-NG Mode")

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:      qsTr("Standalone Mode")
                enabled:   !_busy
                onClicked: _switchWfb("standalone")
            }

            QGCButton {
                text:      qsTr("Cluster Mode")
                enabled:   !_busy
                onClicked: _switchWfb("cluster")
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:      qsTr("Refresh")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.relay.wfbRefresh())
            }

            QGCButton {
                text:      qsTr("Status")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.relay.wfbStatus())
            }

            QGCButton {
                text:      qsTr("Logs")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.relay.wfbLogs())
            }

            QGCButton {
                text:      qsTr("View Config")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.relay.wfbViewConfig())
            }
        }
    }

    // -----------------------------------------------------------------------
    // NICs
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("WFB NICs")

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:      qsTr("List NICs")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.relay.wfbListNics())
            }

            QGCLabel { text: qsTr("Set NICs:") }

            QGCTextField {
                id:              nicsField
                Layout.fillWidth: true
                placeholderText:  qsTr("e.g. wlx00c0cab6db3b")
            }

            QGCButton {
                text:      qsTr("Set NICs")
                enabled:   !_busy && nicsField.text.trim() !== ""
                onClicked: _dispatch(Pxlabs.relay.wfbSetNics(nicsField.text.trim()))
            }
        }
    }

    // -----------------------------------------------------------------------
    // System
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Relay System")

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:      qsTr("SSH Terminal")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.relay.sshTerminal())
            }

            QGCButton {
                text:      qsTr("Reboot")
                enabled:   !_busy
                onClicked: relayRebootConfirm.visible = true
            }

            QGCButton {
                text:      qsTr("Shutdown")
                enabled:   !_busy
                onClicked: relayShutdownConfirm.visible = true
            }
        }

        ColumnLayout {
            id:      relayRebootConfirm
            visible: false
            Layout.fillWidth: true
            QGCLabel {
                text:  qsTr("Confirm reboot relay station?")
                color: QGroundControl.globalPalette.colorOrange
            }
            RowLayout {
                spacing: ScreenTools.defaultFontPixelWidth
                QGCButton {
                    text:      qsTr("Yes — Reboot")
                    onClicked: { relayRebootConfirm.visible = false; _dispatch(Pxlabs.relay.reboot()) }
                }
                QGCButton {
                    text:      qsTr("Cancel")
                    onClicked: relayRebootConfirm.visible = false
                }
            }
        }

        ColumnLayout {
            id:      relayShutdownConfirm
            visible: false
            Layout.fillWidth: true
            QGCLabel {
                text:  qsTr("Confirm shutdown relay station?")
                color: QGroundControl.globalPalette.colorRed
            }
            RowLayout {
                spacing: ScreenTools.defaultFontPixelWidth
                QGCButton {
                    text:      qsTr("Yes — Shutdown")
                    onClicked: { relayShutdownConfirm.visible = false; _dispatch(Pxlabs.relay.shutdown()) }
                }
                QGCButton {
                    text:      qsTr("Cancel")
                    onClicked: relayShutdownConfirm.visible = false
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Services
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Relay Services")

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
                id:               relaySvcCombo
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
                id:               customRelaySvcField
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
                onClicked: _dispatch(Pxlabs.relay.serviceStart(_resolvedSvc()))
            }

            QGCButton {
                text:      qsTr("Stop")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.relay.serviceStop(_resolvedSvc()))
            }

            QGCButton {
                text:      qsTr("Restart")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.relay.serviceRestart(_resolvedSvc()))
            }

            QGCButton {
                text:      qsTr("Enable")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.relay.serviceEnable(_resolvedSvc()))
            }

            QGCButton {
                text:      qsTr("Disable")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.relay.serviceDisable(_resolvedSvc()))
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
            height:           ScreenTools.defaultFontPixelHeight * 16
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
