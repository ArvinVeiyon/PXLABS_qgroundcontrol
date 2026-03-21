// PXLABS integration — additive file, do not modify existing QGC code
// PXLABSSettings.qml: CLI path / Python path configuration + test.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

import QGroundControl
import QGroundControl.Controls
import QGroundControl.ScreenTools
import QGroundControl.Palette
import QGroundControl.PXLABS

SettingsPage {
    id: root

    property bool _busy: false   // own commands only — not global runner state

    // Keep output area updated
    Connections {
        target: PXLABSRunner
        function onOutputReady(text)         { if (_busy) outputArea.text = text }
        function onCommandFinished(exitCode) {
            if (!_busy) return
            _busy = false
            if (exitCode !== 0) outputArea.text += qsTr("\n[Exit code: %1]").arg(exitCode)
        }
        function onCommandFailed(errorText)  {
            if (!_busy) return
            _busy = false
            outputArea.text = qsTr("ERROR: ") + errorText
        }
    }

    // -----------------------------------------------------------------------
    // CLI Configuration
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("PXLABS CLI Configuration")

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("Python:"); Layout.preferredWidth: ScreenTools.defaultFontPixelWidth * 10 }

            QGCTextField {
                id:               pythonField
                Layout.fillWidth: true
                text:             PXLABSRunner.pythonPath
                placeholderText:  qsTr("python")
            }

            QGCButton {
                text:      qsTr("Save")
                onClicked: PXLABSRunner.setPythonPath(pythonField.text.trim())
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("CLI Path:"); Layout.preferredWidth: ScreenTools.defaultFontPixelWidth * 10 }

            QGCTextField {
                id:               cliField
                Layout.fillWidth: true
                text:             PXLABSRunner.cliPath
                placeholderText:  qsTr("<app dir>/tools/pxlabs_cli.py")
            }

            QGCButton {
                text:      qsTr("Save")
                onClicked: PXLABSRunner.setCliPath(cliField.text.trim())
            }
        }

        QGCLabel {
            Layout.fillWidth: true
            wrapMode:         Text.WordWrap
            font.pointSize:   ScreenTools.smallFontPointSize
            text:             qsTr("Default CLI path: <QGC app dir>\\tools\\pxlabs_cli.py  — copy pxlabs_cli.py from Drone_Control_v2.1/tools/ next to G-Control.exe.")
        }
    }

    // -----------------------------------------------------------------------
    // Test
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Test")

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:      qsTr("Test CLI (config show)")
                enabled:   !_busy
                onClicked: {
                    if (PXLABSRunner.running) {
                        outputArea.text = qsTr("⚠ Runner busy — please retry in a moment.")
                        return
                    }
                    outputArea.text = ""
                    _busy = true
                    PXLABSRunner.run("config show")
                }
            }

            QGCButton {
                text:      qsTr("Abort")
                enabled:   _busy
                onClicked: PXLABSRunner.abort()
            }

            QGCLabel {
                text:    _busy ? qsTr("Running…") : qsTr("Idle")
                color:   _busy ? QGroundControl.globalPalette.colorOrange : QGroundControl.globalPalette.text
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
            height:           ScreenTools.defaultFontPixelHeight * 14
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
