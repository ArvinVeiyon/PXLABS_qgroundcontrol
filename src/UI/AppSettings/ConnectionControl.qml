// PXLABS integration — additive file
// ConnectionControl.qml: SSH config for companion + relay, WiFi temp settings.
// Saves to config/ssh_config.json via "config set" CLI command.
// Passwords saved to Windows keyring via keyring.set_password("Drone-Control", ...).

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

    // ---- load saved values on open ----
    Component.onCompleted: {
        primaryIpField.text       = QGroundControl.loadGlobalSetting("pxlabs_primary_ip",       "10.5.6.101")
        primaryPortField.text     = QGroundControl.loadGlobalSetting("pxlabs_primary_port",     "2222")
        secondaryIpField.text     = QGroundControl.loadGlobalSetting("pxlabs_secondary_ip",     "")
        secondaryPortField.text   = QGroundControl.loadGlobalSetting("pxlabs_secondary_port",   "22")
        compUserField.text        = QGroundControl.loadGlobalSetting("pxlabs_companion_user",   "roz")

        relayIpField.text         = QGroundControl.loadGlobalSetting("pxlabs_relay_ip",         "10.5.6.101")
        relayPortField.text       = QGroundControl.loadGlobalSetting("pxlabs_relay_port",       "22")
        relayUserField.text       = QGroundControl.loadGlobalSetting("pxlabs_relay_user",       "vind-admin")

        connCheckEnable.checked   = QGroundControl.loadGlobalSetting("pxlabs_conn_check_enabled",  "false") === "true"
        connIntervalField.text    = QGroundControl.loadGlobalSetting("pxlabs_conn_check_interval", "300")
        connTimeoutField.text     = QGroundControl.loadGlobalSetting("pxlabs_conn_check_timeout",  "5")
        connAttemptsField.text    = QGroundControl.loadGlobalSetting("pxlabs_conn_check_attempts", "3")

        wifiTempEnable.checked    = QGroundControl.loadGlobalSetting("pxlabs_wifi_temp_enabled",   "false") === "true"
        wifiIntervalField.text    = QGroundControl.loadGlobalSetting("pxlabs_wifi_temp_interval",  "60")
    }

    Connections {
        target: PXLABSRunner
        function onOutputReady(text)         { outputArea.text = text }
        function onCommandFinished(exitCode) {
            if (exitCode !== 0) outputArea.text += qsTr("\n[Exit code: %1]").arg(exitCode)
            else outputArea.text += qsTr("\n✓ Saved")
        }
        function onCommandFailed(errorText)  { outputArea.text = qsTr("ERROR: ") + errorText }
    }

    function _saveCompanion() {
        QGroundControl.saveGlobalSetting("pxlabs_primary_ip",     primaryIpField.text.trim())
        QGroundControl.saveGlobalSetting("pxlabs_primary_port",   primaryPortField.text.trim())
        QGroundControl.saveGlobalSetting("pxlabs_secondary_ip",   secondaryIpField.text.trim())
        QGroundControl.saveGlobalSetting("pxlabs_secondary_port", secondaryPortField.text.trim())
        QGroundControl.saveGlobalSetting("pxlabs_companion_user", compUserField.text.trim())

        outputArea.text = ""
        let args = "config set"
            + " --primary-ip "     + primaryIpField.text.trim()
            + " --primary-port "   + primaryPortField.text.trim()
            + " --secondary-port " + secondaryPortField.text.trim()
            + " --username "       + compUserField.text.trim()
        if (secondaryIpField.text.trim().length > 0)
            args += " --secondary-ip " + secondaryIpField.text.trim()
        if (compPassField.text.length > 0)
            args += " --companion-password " + compPassField.text
        PXLABSRunner.run(args)
    }

    function _saveRelay() {
        QGroundControl.saveGlobalSetting("pxlabs_relay_ip",   relayIpField.text.trim())
        QGroundControl.saveGlobalSetting("pxlabs_relay_port", relayPortField.text.trim())
        QGroundControl.saveGlobalSetting("pxlabs_relay_user", relayUserField.text.trim())

        outputArea.text = ""
        let args = "config set"
            + " --relay-ip "       + relayIpField.text.trim()
            + " --relay-ssh-port " + relayPortField.text.trim()
            + " --relay-username " + relayUserField.text.trim()
        if (relayPassField.text.length > 0)
            args += " --relay-password " + relayPassField.text
        PXLABSRunner.run(args)
    }

    // -----------------------------------------------------------------------
    // Companion SSH
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Companion SSH Configuration")

        RowLayout {
            Layout.fillWidth: true
            QGCLabel { Layout.preferredWidth: lw; text: qsTr("Primary IP") }
            QGCTextField { id: primaryIpField;     Layout.fillWidth: true; placeholderText: "10.5.6.101" }
        }
        RowLayout {
            Layout.fillWidth: true
            QGCLabel { Layout.preferredWidth: lw; text: qsTr("Primary Port") }
            QGCTextField { id: primaryPortField;   Layout.fillWidth: true; placeholderText: "2222" }
        }
        RowLayout {
            Layout.fillWidth: true
            QGCLabel { Layout.preferredWidth: lw; text: qsTr("Secondary IP") }
            QGCTextField { id: secondaryIpField;   Layout.fillWidth: true; placeholderText: qsTr("optional") }
        }
        RowLayout {
            Layout.fillWidth: true
            QGCLabel { Layout.preferredWidth: lw; text: qsTr("Secondary Port") }
            QGCTextField { id: secondaryPortField; Layout.fillWidth: true; placeholderText: "22" }
        }
        RowLayout {
            Layout.fillWidth: true
            QGCLabel { Layout.preferredWidth: lw; text: qsTr("Username") }
            QGCTextField { id: compUserField;      Layout.fillWidth: true; placeholderText: "roz" }
        }
        RowLayout {
            Layout.fillWidth: true
            QGCLabel { Layout.preferredWidth: lw; text: qsTr("Password") }
            QGCTextField {
                id:               compPassField
                Layout.fillWidth: true
                echoMode:         TextInput.Password
                placeholderText:  qsTr("leave blank to keep existing")
            }
        }
        RowLayout {
            Layout.fillWidth: true
            QGCButton {
                text:      qsTr("Apply Companion")
                enabled:   !_busy
                onClicked: _saveCompanion()
            }
        }
    }

    // -----------------------------------------------------------------------
    // Relay SSH
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Relay SSH Configuration")

        RowLayout {
            Layout.fillWidth: true
            QGCLabel { Layout.preferredWidth: lw; text: qsTr("Relay IP") }
            QGCTextField { id: relayIpField;   Layout.fillWidth: true; placeholderText: "10.5.6.101" }
        }
        RowLayout {
            Layout.fillWidth: true
            QGCLabel { Layout.preferredWidth: lw; text: qsTr("Relay Port") }
            QGCTextField { id: relayPortField; Layout.fillWidth: true; placeholderText: "22" }
        }
        RowLayout {
            Layout.fillWidth: true
            QGCLabel { Layout.preferredWidth: lw; text: qsTr("Username") }
            QGCTextField { id: relayUserField; Layout.fillWidth: true; placeholderText: "vind-admin" }
        }
        RowLayout {
            Layout.fillWidth: true
            QGCLabel { Layout.preferredWidth: lw; text: qsTr("Password") }
            QGCTextField {
                id:               relayPassField
                Layout.fillWidth: true
                echoMode:         TextInput.Password
                placeholderText:  qsTr("leave blank to keep existing")
            }
        }
        RowLayout {
            Layout.fillWidth: true
            QGCButton {
                text:      qsTr("Apply Relay")
                enabled:   !_busy
                onClicked: _saveRelay()
            }
        }
    }

    // -----------------------------------------------------------------------
    // Periodic Connection Check
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Periodic Connection Check")

        RowLayout {
            Layout.fillWidth: true
            QGCCheckBoxSlider {
                id:               connCheckEnable
                text:             qsTr("Enable periodic connection check")
                Layout.fillWidth: true
                onCheckedChanged: QGroundControl.saveGlobalSetting("pxlabs_conn_check_enabled", checked ? "true" : "false")
            }
        }
        RowLayout {
            Layout.fillWidth: true
            enabled: connCheckEnable.checked
            QGCLabel { Layout.preferredWidth: lw; text: qsTr("Check Interval (sec)") }
            QGCTextField { id: connIntervalField;  Layout.fillWidth: true; placeholderText: "300"; inputMethodHints: Qt.ImhDigitsOnly }
        }
        RowLayout {
            Layout.fillWidth: true
            enabled: connCheckEnable.checked
            QGCLabel { Layout.preferredWidth: lw; text: qsTr("Timeout (sec)") }
            QGCTextField { id: connTimeoutField;   Layout.fillWidth: true; placeholderText: "5";   inputMethodHints: Qt.ImhDigitsOnly }
        }
        RowLayout {
            Layout.fillWidth: true
            enabled: connCheckEnable.checked
            QGCLabel { Layout.preferredWidth: lw; text: qsTr("Max Attempts") }
            QGCTextField { id: connAttemptsField;  Layout.fillWidth: true; placeholderText: "3";   inputMethodHints: Qt.ImhDigitsOnly }
        }
        RowLayout {
            Layout.fillWidth: true
            QGCButton {
                text:      qsTr("Apply")
                onClicked: {
                    QGroundControl.saveGlobalSetting("pxlabs_conn_check_interval", connIntervalField.text.trim())
                    QGroundControl.saveGlobalSetting("pxlabs_conn_check_timeout",  connTimeoutField.text.trim())
                    QGroundControl.saveGlobalSetting("pxlabs_conn_check_attempts", connAttemptsField.text.trim())
                    outputArea.text = qsTr("✓ Connection check settings saved.")
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Wi-Fi Temperature Polling
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Wi-Fi Temperature Polling")

        RowLayout {
            Layout.fillWidth: true
            QGCCheckBoxSlider {
                id:               wifiTempEnable
                text:             qsTr("Enable Wi-Fi temperature display in toolbar")
                Layout.fillWidth: true
                onCheckedChanged: QGroundControl.saveGlobalSetting("pxlabs_wifi_temp_enabled", checked ? "true" : "false")
            }
        }
        RowLayout {
            Layout.fillWidth: true
            enabled: wifiTempEnable.checked
            QGCLabel { Layout.preferredWidth: lw; text: qsTr("Poll Interval (sec)") }
            QGCTextField { id: wifiIntervalField; Layout.fillWidth: true; placeholderText: "60"; inputMethodHints: Qt.ImhDigitsOnly }
        }
        RowLayout {
            Layout.fillWidth: true
            QGCButton {
                text:      qsTr("Apply")
                onClicked: {
                    QGroundControl.saveGlobalSetting("pxlabs_wifi_temp_interval", wifiIntervalField.text.trim())
                    outputArea.text = qsTr("✓ Wi-Fi polling settings saved. Restart fly view to apply interval change.")
                }
            }
        }
        QGCLabel {
            Layout.fillWidth: true
            wrapMode:       Text.WordWrap
            font.pointSize: ScreenTools.smallFontPointSize
            color:          QGroundControl.globalPalette.colorGrey
            text:           qsTr("Changes take effect when the fly view is reloaded. Enable/disable is immediate.")
        }
    }

    // -----------------------------------------------------------------------
    // Runner status
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Status")

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
                text:      qsTr("Show Config")
                enabled:   !_busy
                onClicked: { outputArea.text = ""; PXLABSRunner.run("config show") }
            }

            QGCButton {
                text:      qsTr("Clear")
                onClicked: outputArea.text = ""
            }
        }

        TextArea {
            id:               outputArea
            Layout.fillWidth: true
            height:           ScreenTools.defaultFontPixelHeight * 10
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

    property real lw: ScreenTools.defaultFontPixelWidth * 16
}
