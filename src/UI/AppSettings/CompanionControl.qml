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

    property bool   _busy:  PXLABSRunner.running
    property string _swap:  swapCheck.checked ? " --swap" : ""

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
    // Capture
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Capture (saves to Pictures\\)")

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:      qsTr("Capture Front")
                enabled:   !_busy
                onClicked: _run("companion capture-front" + _swap)
            }

            QGCButton {
                text:      qsTr("Capture Bottom")
                enabled:   !_busy
                onClicked: _run("companion capture-bottom" + _swap)
            }
        }
    }

    // -----------------------------------------------------------------------
    // Camera Apply / Query
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Camera Device (Advanced)")

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("Device:") }

            QGCComboBox {
                id:    deviceCombo
                model: ["/dev/video0", "/dev/video2", "/dev/video3"]
            }

            QGCButton {
                text:      qsTr("Apply Camera")
                enabled:   !_busy
                onClicked: _run("companion camera-apply --device " + deviceCombo.currentText)
            }

            QGCButton {
                text:      qsTr("Query Formats")
                enabled:   !_busy
                onClicked: _run("companion camera-query --device " + deviceCombo.currentText)
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
                onClicked: _run("services refresh --target companion")
            }
        }

        // Service selector + actions
        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("Service:") }

            QGCComboBox {
                id:    svcCombo
                Layout.fillWidth: true
                model: [
                    "mavlink.router.service",
                    "microxrce-agent.service",
                    "rc_control_node.service",
                    "vision_streaming.service",
                    "tfmini.service",
                    "ros2_px4_translation_node.service",
                    "block-traffic.service",
                    "wifibroadcast@drone.service",
                    "system_files_sync.timer"
                ]
            }

            QGCButton {
                text:      qsTr("Start")
                enabled:   !_busy
                onClicked: _run("services start --target companion --service " + svcCombo.currentText)
            }

            QGCButton {
                text:      qsTr("Stop")
                enabled:   !_busy
                onClicked: _run("services stop --target companion --service " + svcCombo.currentText)
            }

            QGCButton {
                text:      qsTr("Restart")
                enabled:   !_busy
                onClicked: _run("services restart --target companion --service " + svcCombo.currentText)
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
