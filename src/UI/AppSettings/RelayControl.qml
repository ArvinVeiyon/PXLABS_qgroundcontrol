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

    property bool _busy: PXLABSRunner.running

    function _run(args) {
        outputArea.text = ""
        PXLABSRunner.run(args)
    }

    Connections {
        target: PXLABSRunner
        function onOutputReady(text)         { outputArea.text = text }
        function onCommandFinished(exitCode) {
            if (exitCode !== 0) outputArea.text += qsTr("\n[Exit code: %1]").arg(exitCode)
        }
        function onCommandFailed(errorText)  { outputArea.text = qsTr("ERROR: ") + errorText }
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
                onClicked: _run("relay wfb switch --mode standalone")
            }

            QGCButton {
                text:      qsTr("Cluster Mode")
                enabled:   !_busy
                onClicked: _run("relay wfb switch --mode cluster")
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:      qsTr("Refresh")
                enabled:   !_busy
                onClicked: _run("relay wfb refresh")
            }

            QGCButton {
                text:      qsTr("Status")
                enabled:   !_busy
                onClicked: _run("relay wfb status")
            }

            QGCButton {
                text:      qsTr("Logs")
                enabled:   !_busy
                onClicked: _run("relay wfb logs")
            }

            QGCButton {
                text:      qsTr("View Config")
                enabled:   !_busy
                onClicked: _run("relay wfb view-config")
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
                onClicked: _run("relay wfb list-nics")
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
                onClicked: _run("relay wfb set-nics --nics " + nicsField.text.trim())
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
                onClicked: _run("relay ssh-terminal")
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
                    onClicked: { relayRebootConfirm.visible = false; _run("relay reboot") }
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
                    onClicked: { relayShutdownConfirm.visible = false; _run("relay shutdown") }
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
                onClicked: _run("services refresh --target relay")
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("Service:") }

            QGCComboBox {
                id:    relaySvcCombo
                Layout.fillWidth: true
                model: [
                    "wifibroadcast@gs.service",
                    "mavlink.router.service",
                    "ssh-tunnel-to-companion.service",
                    "relay_files_sync.timer",
                    "mediamtx.service",
                    "isc-dhcp-server.service"
                ]
            }

            QGCButton {
                text:      qsTr("Start")
                enabled:   !_busy
                onClicked: _run("services start --target relay --service " + relaySvcCombo.currentText)
            }

            QGCButton {
                text:      qsTr("Stop")
                enabled:   !_busy
                onClicked: _run("services stop --target relay --service " + relaySvcCombo.currentText)
            }

            QGCButton {
                text:      qsTr("Restart")
                enabled:   !_busy
                onClicked: _run("services restart --target relay --service " + relaySvcCombo.currentText)
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
