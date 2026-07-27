// PXLABS integration — additive file, do not modify existing QGC code
// WFBConfig.qml: safe wifibroadcast.cfg editor for companion (drone) and relay (gs).
//
// Fleet convention: the two configs stay IDENTICAL. "Apply to Link" sends every
// change to BOTH ends (companion first, then relay) with a matched-ends
// guarantee — neither side keeps the new config unless both do. The sole
// per-side parameter is wifi_txpower (drone thermal vs ground amp), which has
// its own apply button targeting the selected node. Channel/bandwidth remain
// gated behind a live secondary-connection check and a danger acknowledgement.
//
// Every apply runs through wfb-cfg-apply on the device: if the ground cannot
// reconfirm within the timeout, the device restores the previous config and
// restarts WFB by itself — a bad setting can not permanently kill the link.

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

    property bool _busy:         false
    property bool _secondaryOk:  false
    property var  _loaded:       ({})     // params as loaded from the device
    property bool _cfgLoaded:    Object.keys(_loaded).length > 0

    property var _node: targetCombo.currentIndex === 1 ? Pxlabs.relay : Pxlabs.companion

    Component.onCompleted: {
        _loadParams()
        _loadSecondaryCfg()
    }

    // 5 GHz channels usable with wfb-ng (region BO)
    readonly property var _channels: [ "36","40","44","48","52","56","60","64",
                                       "100","104","108","112","116","120","124","128",
                                       "132","136","140","144","149","153","157","161",
                                       "165","169","173","177" ]
    readonly property var _fecK: [ "1","2","3","4","5","6","7","8","9","10","11","12" ]
    readonly property var _fecN: [ "2","3","4","5","6","7","8","9","10","11","12","13","14","15","16" ]

    function _dispatch(req) {
        _busy = true
        outputArea.text = ""
        req.outputChanged.connect(function() { outputArea.text = req.output })
        req.succeeded.connect(function(exitCode) { _busy = false })
        req.failed.connect(function(errorText) {
            _busy = false
            // req.output already carries the real captured stdout/stderr — don't
            // let the generic "exit 1" message stomp it (see camera-outage postmortem).
            var body = req.output ? req.output.trim() : ""
            outputArea.text = (body.length > 0 ? body + "\n\n" : "") + qsTr("ERROR: ") + errorText
        })
        return req
    }

    // Parse `section.key=value [TIERn]` lines into the form fields.
    function _loadParams() {
        var req = _dispatch(_node.wfbCfgParams())
        req.succeeded.connect(function() {
            var vals = {}
            var lines = req.output.split('\n')
            for (var i = 0; i < lines.length; i++) {
                var m = lines[i].trim().match(/^([\w.]+)=(\S+)\s/)
                if (m) vals[m[1]] = m[2]
            }
            _loaded = vals
            function idx(list, v) { var i = list.indexOf(String(v)); return i < 0 ? 0 : i }
            if ("base.mcs_index" in vals)      mcsCombo.currentIndex = parseInt(vals["base.mcs_index"])
            if ("common.wifi_txpower" in vals) txpowerField.text  = vals["common.wifi_txpower"]
            if ("base.stbc" in vals)           stbcSwitch.checked = vals["base.stbc"] === "1"
            if ("base.ldpc" in vals)           ldpcSwitch.checked = vals["base.ldpc"] === "1"
            if ("video.fec_k" in vals)         videoK.currentIndex   = idx(_fecK, vals["video.fec_k"])
            if ("video.fec_n" in vals)         videoN.currentIndex   = idx(_fecN, vals["video.fec_n"])
            if ("mavlink.fec_k" in vals)       mavlinkK.currentIndex = idx(_fecK, vals["mavlink.fec_k"])
            if ("mavlink.fec_n" in vals)       mavlinkN.currentIndex = idx(_fecN, vals["mavlink.fec_n"])
            if ("tunnel.fec_k" in vals)        tunnelK.currentIndex  = idx(_fecK, vals["tunnel.fec_k"])
            if ("tunnel.fec_n" in vals)        tunnelN.currentIndex  = idx(_fecN, vals["tunnel.fec_n"])
            if ("common.wifi_channel" in vals) channelCombo.currentIndex = idx(_channels, vals["common.wifi_channel"])
            if ("base.bandwidth" in vals)      bwCombo.currentIndex = vals["base.bandwidth"] === "40" ? 1 : 0
            outputArea.text = qsTr("Loaded current config from ") + targetCombo.currentText
        })
    }

    // Silent prefill of the secondary-link fields from the saved CLI config.
    function _loadSecondaryCfg() {
        var req = Pxlabs.configShow()
        req.succeeded.connect(function() {
            try {
                var txt = req.output
                var o = JSON.parse(txt.substring(txt.indexOf('{'), txt.lastIndexOf('}') + 1))
                if (o.secondary_ip)   secIpField.text   = o.secondary_ip
                if (o.secondary_port) secPortField.text = String(o.secondary_port)
            } catch (e) { /* leave fields empty */ }
        })
    }

    // Only send what actually changed. txpower is per-side — never part of the
    // both-ends diff (see _txpowerChanged / _applyTxpower).
    function _changedParams(includeDanger) {
        var out = []
        function chk(name, val) {
            if (name in _loaded && String(val) !== String(_loaded[name])) out.push(name + "=" + val)
        }
        chk("base.mcs_index",      mcsCombo.currentIndex)
        chk("base.stbc",           stbcSwitch.checked ? 1 : 0)
        chk("base.ldpc",           ldpcSwitch.checked ? 1 : 0)
        chk("video.fec_k",         videoK.currentText)
        chk("video.fec_n",         videoN.currentText)
        chk("mavlink.fec_k",       mavlinkK.currentText)
        chk("mavlink.fec_n",       mavlinkN.currentText)
        chk("tunnel.fec_k",        tunnelK.currentText)
        chk("tunnel.fec_n",        tunnelN.currentText)
        if (includeDanger) {
            chk("common.wifi_channel", channelCombo.currentText)
            chk("base.bandwidth",      bwCombo.currentText)
        }
        return out
    }

    function _hasDangerChange() {
        return ("common.wifi_channel" in _loaded &&
                channelCombo.currentText !== String(_loaded["common.wifi_channel"])) ||
               ("base.bandwidth" in _loaded &&
                bwCombo.currentText !== String(_loaded["base.bandwidth"]))
    }

    function _checkSecondary() {
        var req = _dispatch(Pxlabs.wfbCfgCheckSecondary())
        req.completeChanged.connect(function() {
            if (req.complete) _secondaryOk = req.output.indexOf("SECONDARY:reachable") >= 0
        })
    }

    function _txpowerChanged() {
        return "common.wifi_txpower" in _loaded &&
               txpowerField.text.trim() !== String(_loaded["common.wifi_txpower"])
    }

    // Apply to Link: everything except txpower, to BOTH ends.
    function _apply() {
        var danger = _hasDangerChange()
        var params = _changedParams(danger)
        if (params.length === 0) {
            outputArea.text = qsTr("No changes to apply.")
            return
        }
        applyConfirm.paramsText = params.join(", ")
        applyConfirm.params     = params.join(",")
        applyConfirm.danger     = danger
        applyConfirm.both       = true
        applyConfirm.visible    = true
    }

    // TX power: the selected target only.
    function _applyTxpower() {
        if (!_txpowerChanged()) {
            outputArea.text = qsTr("TX power unchanged.")
            return
        }
        applyConfirm.paramsText = "common.wifi_txpower=" + txpowerField.text.trim()
        applyConfirm.params     = applyConfirm.paramsText
        applyConfirm.danger     = false
        applyConfirm.both       = false
        applyConfirm.visible    = true
    }

    // -----------------------------------------------------------------------
    // Target + load
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("WFB Link Configuration")

        RowLayout {
            Layout.fillWidth: true
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("View target:") }

            QGCComboBox {
                id:    targetCombo
                model: [ qsTr("Companion (drone)"), qsTr("Relay (ground)") ]
                sizeToContents: true
                // Baseline belongs to ONE device — drop it and reload on switch
                // so diffs are never computed against the other side's values.
                onCurrentIndexChanged: {
                    _loaded = {}
                    _loadParams()
                }
            }

            QGCButton {
                text:      qsTr("Reload")
                enabled:   !_busy
                onClicked: _loadParams()
            }

            QGCButton {
                text:      qsTr("View Full Config")
                enabled:   !_busy
                onClicked: _dispatch(_node.wfbCfgGet())
            }
        }

        QGCLabel {
            Layout.fillWidth: true
            wrapMode:         Text.WordWrap
            font.pointSize:   ScreenTools.smallFontPointSize
            color:            QGroundControl.globalPalette.colorGrey
            text: qsTr("Changes apply to BOTH ends (companion first, then relay) so the " +
                       "configs stay identical — neither side keeps a new config unless " +
                       "both confirm, otherwise both roll back automatically. " +
                       "Only TX power is per-side.")
        }
    }

    // -----------------------------------------------------------------------
    // TIER 1 — link tuning (applied to both ends)
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("RF Tuning (applied to both ends)")

        RowLayout {
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("MCS:") }
            QGCComboBox {
                id:    mcsCombo
                model: [ "0 (6.5 Mbit)", "1 (13 Mbit)", "2 (19.5 Mbit)", "3 (26 Mbit)",
                         "4 (39 Mbit)", "5 (52 Mbit)", "6 (58.5 Mbit)", "7 (65 Mbit)" ]
                sizeToContents: true
            }

            QGCLabel { text: qsTr("STBC") }
            Switch { id: stbcSwitch }

            QGCLabel { text: qsTr("LDPC") }
            Switch { id: ldpcSwitch }
        }

        RowLayout {
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("TX power (dBm×100, per-side):") }
            QGCTextField {
                id:                  txpowerField
                Layout.preferredWidth: ScreenTools.defaultFontPixelWidth * 10
                placeholderText:     "3000"
            }
            QGCButton {
                text:      qsTr("Apply TX Power → %1").arg(targetCombo.currentText)
                enabled:   !_busy && _cfgLoaded
                onClicked: _applyTxpower()
            }
        }

        GridLayout {
            columns:       5
            columnSpacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("FEC") ; font.bold: true }
            QGCLabel { text: qsTr("k (data)") }
            QGCLabel { text: qsTr("n (total)") }
            QGCLabel { text: qsTr("spares") ; color: QGroundControl.globalPalette.colorGrey }
            QGCLabel { text: "" }

            QGCLabel { text: qsTr("Video") }
            QGCComboBox { id: videoK; model: _fecK; sizeToContents: true }
            QGCComboBox { id: videoN; model: _fecN; sizeToContents: true }
            QGCLabel {
                text:  (parseInt(videoN.currentText) - parseInt(videoK.currentText)) >= 0 ?
                       String(parseInt(videoN.currentText) - parseInt(videoK.currentText)) : "—"
                color: QGroundControl.globalPalette.colorGrey
            }
            QGCLabel { text: "" }

            QGCLabel { text: qsTr("MAVLink") }
            QGCComboBox { id: mavlinkK; model: _fecK; sizeToContents: true }
            QGCComboBox { id: mavlinkN; model: _fecN; sizeToContents: true }
            QGCLabel {
                text:  (parseInt(mavlinkN.currentText) - parseInt(mavlinkK.currentText)) >= 0 ?
                       String(parseInt(mavlinkN.currentText) - parseInt(mavlinkK.currentText)) : "—"
                color: QGroundControl.globalPalette.colorGrey
            }
            QGCLabel { text: "" }

            QGCLabel { text: qsTr("Tunnel") }
            QGCComboBox { id: tunnelK; model: _fecK; sizeToContents: true }
            QGCComboBox { id: tunnelN; model: _fecN; sizeToContents: true }
            QGCLabel {
                text:  (parseInt(tunnelN.currentText) - parseInt(tunnelK.currentText)) >= 0 ?
                       String(parseInt(tunnelN.currentText) - parseInt(tunnelK.currentText)) : "—"
                color: QGroundControl.globalPalette.colorGrey
            }
            QGCLabel { text: "" }
        }
    }

    // -----------------------------------------------------------------------
    // TIER 2 — dangerous (both ends must match)
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Channel / Bandwidth (DANGER — must match both ends)")

        QGCLabel {
            Layout.fillWidth: true
            wrapMode:         Text.WordWrap
            font.pointSize:   ScreenTools.smallFontPointSize
            color:            QGroundControl.globalPalette.colorOrange
            text: qsTr("Changing these on one side only breaks the link until the other side " +
                       "matches. Editing requires a working secondary connection to the companion " +
                       "(onboard WiFi / 4G) as a recovery path.")
        }

        RowLayout {
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("Secondary IP:") }
            QGCTextField {
                id:                    secIpField
                Layout.preferredWidth: ScreenTools.defaultFontPixelWidth * 16
                placeholderText:       qsTr("companion via onboard WiFi")
            }

            QGCLabel { text: qsTr("Port:") }
            QGCTextField {
                id:                    secPortField
                Layout.preferredWidth: ScreenTools.defaultFontPixelWidth * 6
                text:                  "22"
            }

            QGCButton {
                text:    qsTr("Save")
                enabled: !_busy && secIpField.text.trim().length > 0
                onClicked: {
                    _secondaryOk = false    // new route must be re-checked
                    _dispatch(Pxlabs.configSet({ "secondary-ip":   secIpField.text.trim(),
                                                 "secondary-port": secPortField.text.trim() || "22" }))
                }
            }

            QGCButton {
                text:      _secondaryOk ? qsTr("Secondary: OK ✓") : qsTr("Check Secondary Link")
                enabled:   !_busy
                onClicked: _checkSecondary()
            }
        }

        RowLayout {
            spacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("Channel:") }
            QGCComboBox {
                id:             channelCombo
                enabled:        _secondaryOk
                model:          _channels
                sizeToContents: true
            }

            QGCLabel { text: qsTr("Bandwidth:") }
            QGCComboBox {
                id:      bwCombo
                enabled: _secondaryOk
                model:   [ "20", "40" ]
                sizeToContents: true
            }
        }
    }

    // -----------------------------------------------------------------------
    // Apply / restore
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Apply")

        RowLayout {
            spacing: ScreenTools.defaultFontPixelWidth

            QGCButton {
                text:      qsTr("Apply to Link (both ends)")
                enabled:   !_busy && _cfgLoaded
                onClicked: _apply()
            }

            QGCButton {
                text:      qsTr("Restore Default Config (%1)").arg(targetCombo.currentText)
                enabled:   !_busy
                onClicked: restoreConfirm.visible = true
            }

            QGCButton {
                text:      qsTr("Clear Output")
                onClicked: outputArea.text = ""
            }
        }

        // Apply confirmation
        ColumnLayout {
            id:      applyConfirm
            visible: false
            Layout.fillWidth: true

            property string paramsText: ""
            property string params:     ""
            property bool   danger:     false
            property bool   both:       true

            QGCLabel {
                Layout.fillWidth: true
                wrapMode:         Text.WordWrap
                color:            applyConfirm.danger ? QGroundControl.globalPalette.colorRed
                                                      : QGroundControl.globalPalette.colorOrange
                text: (applyConfirm.danger ? qsTr("DANGER (channel/bandwidth): ") : qsTr("Apply: "))
                      + applyConfirm.paramsText
                      + qsTr("  →  ")
                      + (applyConfirm.both ? qsTr("BOTH ends (companion first, then relay)")
                                           : targetCombo.currentText)
            }
            RowLayout {
                spacing: ScreenTools.defaultFontPixelWidth
                QGCButton {
                    text:      qsTr("Yes — Apply (watchdog-guarded)")
                    onClicked: {
                        applyConfirm.visible = false
                        var req = applyConfirm.both
                                ? _dispatch(Pxlabs.wfbCfgSetBoth(applyConfirm.params, applyConfirm.danger,
                                                                 applyConfirm.danger ? 120 : 60))
                                : _dispatch(_node.wfbCfgSet(applyConfirm.params, false, 60))
                        // Exit 0 == confirmed & kept — fold the applied values into the
                        // baseline so the next diff starts from what is now on the device.
                        var applied = applyConfirm.params
                        req.succeeded.connect(function() {
                            var nl = {}
                            for (var k in _loaded) nl[k] = _loaded[k]
                            var parts = applied.split(",")
                            for (var i = 0; i < parts.length; i++) {
                                var kv = parts[i].split("=")
                                if (kv.length === 2) nl[kv[0]] = kv[1]
                            }
                            _loaded = nl
                        })
                    }
                }
                QGCButton {
                    text:      qsTr("Cancel")
                    onClicked: applyConfirm.visible = false
                }
            }
        }

        // Restore-default confirmation
        ColumnLayout {
            id:      restoreConfirm
            visible: false
            Layout.fillWidth: true

            QGCLabel {
                text:  qsTr("Restore factory-default wifibroadcast.cfg on %1?").arg(targetCombo.currentText)
                color: QGroundControl.globalPalette.colorOrange
            }
            RowLayout {
                spacing: ScreenTools.defaultFontPixelWidth
                QGCButton {
                    text:      qsTr("Yes — Restore Default")
                    onClicked: { restoreConfirm.visible = false; _dispatch(_node.wfbCfgRestoreDefault(60)) }
                }
                QGCButton {
                    text:      qsTr("Cancel")
                    onClicked: restoreConfirm.visible = false
                }
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
            height:           ScreenTools.defaultFontPixelHeight * 12
            readOnly:         true
            font.family:      "Courier New"
            font.pointSize:   ScreenTools.smallFontPointSize
            wrapMode:         TextArea.Wrap
            color:            "#D8D8D8"
            text:             qsTr("(loading current config…)")
            background: Rectangle {
                color:        QGroundControl.globalPalette.windowShade
                radius:       3
                border.color: QGroundControl.globalPalette.button
                border.width: 1
            }
        }
    }
}
