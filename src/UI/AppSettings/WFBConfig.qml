// PXLABS integration — additive file, do not modify existing QGC code
// WFBConfig.qml: safe wifibroadcast.cfg editor for companion (drone) and relay (gs).
//
// The page is split by WHICH NODE TRANSMITS, because that is the only axis
// wfb-ng cares about. stbc / ldpc / mcs_index / short_gi are transmit-only
// radiotap flags (master.cfg: "Radiotap flags for TX") — they shape what a node
// sends and say nothing about what it receives. Proof from the live relay:
//   wfb_rx -p 0  -c ... 5600 ...                    <- no radio args at all
//   wfb_tx -p 144 ... -B 20 -G long -S 0 -L 0 -M 1  <- uplink only
// So the drone's values own the DOWNLINK and the relay's own the UPLINK, and
// forcing them to match (as this page used to) is wrong: it pushes the drone's
// radio onto a ground station whose cards may not support it.
//
// FEC is likewise TX-side only ("Rx will get FEC settings from session packet"),
// and the ground station runs no video TX at all — gs_video is udp_direct_rx
// with stream_tx: None — so video FEC is omitted from the uplink section.
//
// Only wifi_channel and bandwidth must match both ends; they stay gated behind
// a live secondary-link check and a danger acknowledgement.
//
// Two ways to change the radio:
//   "Try Live"  — wfb_tx_cmd rewrites the radiotap header of the running
//                 wfb_tx. Nothing on disk changes, the device self-reverts if
//                 the ground cannot re-confirm, and a unit restart also undoes
//                 it. Use this to find out what the cards actually support.
//   "Save"      — edits wifibroadcast.cfg through wfb-cfg-apply, which restores
//                 the previous config by itself if the ground goes quiet.

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

    property bool _busy:        false
    property bool _secondaryOk: false

    // Config values as loaded from each device — the diff baselines.
    property var  _drone: ({})
    property var  _relay: ({})
    property bool _droneLoaded: Object.keys(_drone).length > 0
    property bool _relayLoaded: Object.keys(_relay).length > 0

    // "standalone" | "cluster" | "" (unknown). Never persisted, always fetched.
    property string _relayMode: ""

    Component.onCompleted: {
        _loadSide(Pxlabs.companion, "drone")
        _loadSide(Pxlabs.relay,     "relay")
        _loadRelayMode()
        _loadSecondaryCfg()
    }

    readonly property var _channels: [ "36","40","44","48","52","56","60","64",
                                       "100","104","108","112","116","120","124","128",
                                       "132","136","140","144","149","153","157","161",
                                       "165","169","173","177" ]
    readonly property var _fecK:  [ "1","2","3","4","5","6","7","8","9","10","11","12" ]
    readonly property var _fecN:  [ "2","3","4","5","6","7","8","9","10","11","12","13","14","15","16" ]
    // stbc is a spatial-stream count, not a flag: init_radiotap_header accepts
    // 0-3 and throws "Unsupported HT STBC type" above that.
    readonly property var _stbc:  [ "0 (off)", "1", "2", "3" ]
    readonly property var _mcs:   [ "0 (6.5 Mbit)", "1 (13 Mbit)", "2 (19.5 Mbit)", "3 (26 Mbit)",
                                    "4 (39 Mbit)", "5 (52 Mbit)", "6 (58.5 Mbit)", "7 (65 Mbit)" ]

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

    function _idx(list, v) {
        for (var i = 0; i < list.length; i++) {
            if (list[i] === String(v) || list[i].indexOf(String(v) + " ") === 0) return i
        }
        return 0
    }

    // Parse `section.key=value [TIERn]` lines into one side's form fields.
    function _loadSide(node, which) {
        var req = _dispatch(node.wfbCfgParams())
        req.succeeded.connect(function() {
            var vals = {}
            var lines = req.output.split('\n')
            for (var i = 0; i < lines.length; i++) {
                var m = lines[i].trim().match(/^([\w.]+)=(\S+)\s/)
                if (m) vals[m[1]] = m[2]
            }
            if (which === "drone") {
                _drone = vals
                if ("base.stbc"      in vals) dStbc.currentIndex = _idx(_stbc, vals["base.stbc"])
                if ("base.ldpc"      in vals) dLdpc.checked      = vals["base.ldpc"] === "1"
                if ("base.mcs_index" in vals) dMcs.currentIndex  = parseInt(vals["base.mcs_index"])
                if ("common.wifi_txpower" in vals) dTxpower.text = vals["common.wifi_txpower"]
                if ("video.fec_k"    in vals) dVideoK.currentIndex   = _idx(_fecK, vals["video.fec_k"])
                if ("video.fec_n"    in vals) dVideoN.currentIndex   = _idx(_fecN, vals["video.fec_n"])
                if ("mavlink.fec_k"  in vals) dMavK.currentIndex     = _idx(_fecK, vals["mavlink.fec_k"])
                if ("mavlink.fec_n"  in vals) dMavN.currentIndex     = _idx(_fecN, vals["mavlink.fec_n"])
                if ("tunnel.fec_k"   in vals) dTunK.currentIndex     = _idx(_fecK, vals["tunnel.fec_k"])
                if ("tunnel.fec_n"   in vals) dTunN.currentIndex     = _idx(_fecN, vals["tunnel.fec_n"])
                if ("common.wifi_channel" in vals) channelCombo.currentIndex = _idx(_channels, vals["common.wifi_channel"])
                if ("base.bandwidth" in vals) bwCombo.currentIndex = vals["base.bandwidth"] === "40" ? 1 : 0
            } else {
                _relay = vals
                if ("base.stbc"      in vals) rStbc.currentIndex = _idx(_stbc, vals["base.stbc"])
                if ("base.ldpc"      in vals) rLdpc.checked      = vals["base.ldpc"] === "1"
                if ("base.mcs_index" in vals) rMcs.currentIndex  = parseInt(vals["base.mcs_index"])
                if ("common.wifi_txpower" in vals) rTxpower.text = vals["common.wifi_txpower"]
                if ("mavlink.fec_k"  in vals) rMavK.currentIndex = _idx(_fecK, vals["mavlink.fec_k"])
                if ("mavlink.fec_n"  in vals) rMavN.currentIndex = _idx(_fecN, vals["mavlink.fec_n"])
                if ("tunnel.fec_k"   in vals) rTunK.currentIndex = _idx(_fecK, vals["tunnel.fec_k"])
                if ("tunnel.fec_n"   in vals) rTunN.currentIndex = _idx(_fecN, vals["tunnel.fec_n"])
            }
            outputArea.text = qsTr("Loaded %1 config").arg(which)
        })
    }

    // Cluster vs standalone decides which warnings the uplink section shows.
    function _loadRelayMode() {
        var req = Pxlabs.relay.wfbRefresh(true)
        req.succeeded.connect(function() {
            var sa = "", ca = ""
            var lines = req.output.split('\n')
            for (var i = 0; i < lines.length; i++) {
                var t = lines[i].trim()
                if (t.indexOf("SA:") === 0) sa = t.substring(3).trim()
                if (t.indexOf("CA:") === 0) ca = t.substring(3).trim()
            }
            if (ca === "active" && sa !== "active")      _relayMode = "cluster"
            else if (sa === "active")                    _relayMode = "standalone"
            else                                         _relayMode = ""
        })
    }

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

    function _num(comboText) { return parseInt(comboText) }

    // Per-side diff against that side's own baseline. Nothing is ever copied
    // from one node to the other.
    function _droneChanges() {
        var out = []
        function chk(name, val) {
            if (name in _drone && String(val) !== String(_drone[name])) out.push(name + "=" + val)
        }
        chk("base.stbc",           _num(dStbc.currentText))
        chk("base.ldpc",           dLdpc.checked ? 1 : 0)
        chk("base.mcs_index",      dMcs.currentIndex)
        chk("common.wifi_txpower", dTxpower.text.trim())
        chk("video.fec_k",         dVideoK.currentText)
        chk("video.fec_n",         dVideoN.currentText)
        chk("mavlink.fec_k",       dMavK.currentText)
        chk("mavlink.fec_n",       dMavN.currentText)
        chk("tunnel.fec_k",        dTunK.currentText)
        chk("tunnel.fec_n",        dTunN.currentText)
        return out
    }

    function _relayChanges() {
        var out = []
        function chk(name, val) {
            if (name in _relay && String(val) !== String(_relay[name])) out.push(name + "=" + val)
        }
        chk("base.stbc",           _num(rStbc.currentText))
        chk("base.ldpc",           rLdpc.checked ? 1 : 0)
        chk("base.mcs_index",      rMcs.currentIndex)
        chk("common.wifi_txpower", rTxpower.text.trim())
        chk("mavlink.fec_k",       rMavK.currentText)
        chk("mavlink.fec_n",       rMavN.currentText)
        chk("tunnel.fec_k",        rTunK.currentText)
        chk("tunnel.fec_n",        rTunN.currentText)
        return out
    }

    function _hasDangerChange() {
        return ("common.wifi_channel" in _drone &&
                channelCombo.currentText !== String(_drone["common.wifi_channel"])) ||
               ("base.bandwidth" in _drone &&
                bwCombo.currentText !== String(_drone["base.bandwidth"]))
    }

    function _checkSecondary() {
        var req = _dispatch(Pxlabs.wfbCfgCheckSecondary())
        req.completeChanged.connect(function() {
            if (req.complete) _secondaryOk = req.output.indexOf("SECONDARY:reachable") >= 0
        })
    }

    // Save (cfg edit, watchdog-guarded) for one side only.
    function _save(which) {
        var params = which === "drone" ? _droneChanges() : _relayChanges()
        if (params.length === 0) {
            outputArea.text = qsTr("No changes on the %1 side.").arg(which)
            return
        }
        confirmBox.which      = which
        confirmBox.live       = false
        confirmBox.danger     = false
        confirmBox.paramsText = params.join(", ")
        confirmBox.params     = params.join(",")
        confirmBox.visible    = true
    }

    // Try Live (wfb_tx_cmd) — radiotap flags only, self-reverting.
    function _tryLive(which) {
        confirmBox.which      = which
        confirmBox.live       = true
        confirmBox.danger     = false
        confirmBox.stbc       = which === "drone" ? _num(dStbc.currentText) : _num(rStbc.currentText)
        confirmBox.ldpc       = (which === "drone" ? dLdpc.checked : rLdpc.checked) ? 1 : 0
        confirmBox.mcs        = which === "drone" ? dMcs.currentIndex : rMcs.currentIndex
        confirmBox.paramsText = qsTr("stbc=%1 ldpc=%2 mcs=%3")
                                .arg(confirmBox.stbc).arg(confirmBox.ldpc).arg(confirmBox.mcs)
        confirmBox.visible    = true
    }

    function _applyDanger() {
        var params = []
        if ("common.wifi_channel" in _drone &&
            channelCombo.currentText !== String(_drone["common.wifi_channel"]))
            params.push("common.wifi_channel=" + channelCombo.currentText)
        if ("base.bandwidth" in _drone &&
            bwCombo.currentText !== String(_drone["base.bandwidth"]))
            params.push("base.bandwidth=" + bwCombo.currentText)
        if (params.length === 0) {
            outputArea.text = qsTr("Channel and bandwidth are unchanged.")
            return
        }
        confirmBox.which      = "both"
        confirmBox.live       = false
        confirmBox.danger     = true
        confirmBox.paramsText = params.join(", ")
        confirmBox.params     = params.join(",")
        confirmBox.visible    = true
    }

    // -----------------------------------------------------------------------
    // How this page works
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("WFB Link Configuration")

        QGCLabel {
            Layout.fillWidth: true
            wrapMode:         Text.WordWrap
            font.pointSize:   ScreenTools.smallFontPointSize
            color:            QGroundControl.globalPalette.colorGrey
            text: qsTr("STBC, LDPC and MCS are transmit-only settings: each node's values " +
                       "control what it sends, not what it receives. The drone's settings own " +
                       "the video downlink; the relay's own the telemetry/RC uplink. They do " +
                       "not need to match and are applied separately. Only channel and " +
                       "bandwidth must match both ends.")
        }

        RowLayout {
            spacing: ScreenTools.defaultFontPixelWidth
            QGCButton {
                text:      qsTr("Reload Both")
                enabled:   !_busy
                onClicked: { _loadSide(Pxlabs.companion, "drone")
                             _loadSide(Pxlabs.relay, "relay")
                             _loadRelayMode() }
            }
            QGCButton {
                text:      qsTr("View Drone Config")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.companion.wfbCfgGet())
            }
            QGCButton {
                text:      qsTr("View Relay Config")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.relay.wfbCfgGet())
            }
        }
    }

    // -----------------------------------------------------------------------
    // Drone TX — downlink
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Drone TX — video/telemetry downlink (companion)")

        RowLayout {
            spacing: ScreenTools.defaultFontPixelWidth
            QGCLabel { text: qsTr("STBC:") }
            QGCComboBox { id: dStbc; model: _stbc; sizeToContents: true }
            QGCLabel { text: qsTr("LDPC") }
            Switch { id: dLdpc }
            QGCLabel { text: qsTr("MCS:") }
            QGCComboBox { id: dMcs; model: _mcs; sizeToContents: true }
        }

        QGCLabel {
            Layout.fillWidth: true
            wrapMode:         Text.WordWrap
            font.pointSize:   ScreenTools.smallFontPointSize
            color:            QGroundControl.globalPalette.colorGrey
            text: qsTr("STBC spreads one spatial stream across the card's transmit chains " +
                       "(1 is the useful value for a 2x2 card). This is separate from the " +
                       "multi-card diversity the drone already gets from udp_proxy. LDPC is " +
                       "documented upstream as 8812au-only — verify it with Try Live before saving.")
        }

        RowLayout {
            spacing: ScreenTools.defaultFontPixelWidth
            QGCLabel { text: qsTr("TX power (dBm x100):") }
            QGCTextField {
                id:                    dTxpower
                Layout.preferredWidth: ScreenTools.defaultFontPixelWidth * 10
                placeholderText:       "3000"
            }
        }

        GridLayout {
            columns:       4
            columnSpacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("FEC"); font.bold: true }
            QGCLabel { text: qsTr("k (data)") }
            QGCLabel { text: qsTr("n (total)") }
            QGCLabel { text: qsTr("spares"); color: QGroundControl.globalPalette.colorGrey }

            QGCLabel { text: qsTr("Video") }
            QGCComboBox { id: dVideoK; model: _fecK; sizeToContents: true }
            QGCComboBox { id: dVideoN; model: _fecN; sizeToContents: true }
            QGCLabel {
                text:  (parseInt(dVideoN.currentText) - parseInt(dVideoK.currentText)) >= 0 ?
                       String(parseInt(dVideoN.currentText) - parseInt(dVideoK.currentText)) : "—"
                color: QGroundControl.globalPalette.colorGrey
            }

            QGCLabel { text: qsTr("MAVLink") }
            QGCComboBox { id: dMavK; model: _fecK; sizeToContents: true }
            QGCComboBox { id: dMavN; model: _fecN; sizeToContents: true }
            QGCLabel {
                text:  (parseInt(dMavN.currentText) - parseInt(dMavK.currentText)) >= 0 ?
                       String(parseInt(dMavN.currentText) - parseInt(dMavK.currentText)) : "—"
                color: QGroundControl.globalPalette.colorGrey
            }

            QGCLabel { text: qsTr("Tunnel") }
            QGCComboBox { id: dTunK; model: _fecK; sizeToContents: true }
            QGCComboBox { id: dTunN; model: _fecN; sizeToContents: true }
            QGCLabel {
                text:  (parseInt(dTunN.currentText) - parseInt(dTunK.currentText)) >= 0 ?
                       String(parseInt(dTunN.currentText) - parseInt(dTunK.currentText)) : "—"
                color: QGroundControl.globalPalette.colorGrey
            }
        }

        RowLayout {
            spacing: ScreenTools.defaultFontPixelWidth
            QGCButton {
                text:      qsTr("Try Live (reverts in 30 s)")
                enabled:   !_busy && _droneLoaded
                onClicked: _tryLive("drone")
            }
            QGCButton {
                text:      qsTr("Save to Drone Config")
                enabled:   !_busy && _droneLoaded
                onClicked: _save("drone")
            }
            QGCButton {
                text:      qsTr("Read Live Radio")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.companion.wfbCfgRadioGet())
            }
        }
    }

    // -----------------------------------------------------------------------
    // Ground TX — uplink
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Ground TX — telemetry/RC uplink (relay)")

        QGCLabel {
            Layout.fillWidth: true
            font.pointSize: ScreenTools.smallFontPointSize
            color: _relayMode === "cluster" ? QGroundControl.globalPalette.colorOrange
                                            : QGroundControl.globalPalette.colorGrey
            text:  _relayMode === "" ? qsTr("Relay mode: unknown")
                                     : qsTr("Relay mode: %1").arg(_relayMode)
        }

        RowLayout {
            spacing: ScreenTools.defaultFontPixelWidth
            QGCLabel { text: qsTr("STBC:") }
            QGCComboBox { id: rStbc; model: _stbc; sizeToContents: true }
            QGCLabel { text: qsTr("LDPC") }
            Switch { id: rLdpc }
            QGCLabel { text: qsTr("MCS:") }
            QGCComboBox { id: rMcs; model: _mcs; sizeToContents: true }
        }

        // In cluster mode the server builds ONE radiotap header and ships it to
        // every node (wfb_tx -d -> RemoteTransmitter); the nodes run
        // wfb_tx -I <port>, an injector that takes no radio arguments at all.
        // So these settings still work — they just cannot differ per node, and
        // the least capable card decides what is safe.
        QGCLabel {
            Layout.fillWidth: true
            visible:          _relayMode === "cluster"
            wrapMode:         Text.WordWrap
            font.pointSize:   ScreenTools.smallFontPointSize
            color:            QGroundControl.globalPalette.colorOrange
            text: qsTr("Cluster mode: one radiotap header is shared by every cluster node — " +
                       "these cannot be set per node, so the least capable card decides. " +
                       "With a mixed cluster (EU card + CPE610/ath9k), keep STBC and LDPC off " +
                       "unless a live test proves otherwise. TX power below does NOT reach " +
                       "nodes that declare their own wifi_txpower — the CPE610 node sets it " +
                       "to None, so its power is controlled on the node itself.")
        }

        RowLayout {
            spacing: ScreenTools.defaultFontPixelWidth
            QGCLabel { text: qsTr("TX power (dBm x100):") }
            QGCTextField {
                id:                    rTxpower
                Layout.preferredWidth: ScreenTools.defaultFontPixelWidth * 10
                placeholderText:       "3000"
            }
        }

        GridLayout {
            columns:       4
            columnSpacing: ScreenTools.defaultFontPixelWidth

            QGCLabel { text: qsTr("FEC"); font.bold: true }
            QGCLabel { text: qsTr("k (data)") }
            QGCLabel { text: qsTr("n (total)") }
            QGCLabel { text: qsTr("spares"); color: QGroundControl.globalPalette.colorGrey }

            QGCLabel { text: qsTr("MAVLink") }
            QGCComboBox { id: rMavK; model: _fecK; sizeToContents: true }
            QGCComboBox { id: rMavN; model: _fecN; sizeToContents: true }
            QGCLabel {
                text:  (parseInt(rMavN.currentText) - parseInt(rMavK.currentText)) >= 0 ?
                       String(parseInt(rMavN.currentText) - parseInt(rMavK.currentText)) : "—"
                color: QGroundControl.globalPalette.colorGrey
            }

            QGCLabel { text: qsTr("Tunnel") }
            QGCComboBox { id: rTunK; model: _fecK; sizeToContents: true }
            QGCComboBox { id: rTunN; model: _fecN; sizeToContents: true }
            QGCLabel {
                text:  (parseInt(rTunN.currentText) - parseInt(rTunK.currentText)) >= 0 ?
                       String(parseInt(rTunN.currentText) - parseInt(rTunK.currentText)) : "—"
                color: QGroundControl.globalPalette.colorGrey
            }
        }

        QGCLabel {
            Layout.fillWidth: true
            wrapMode:         Text.WordWrap
            font.pointSize:   ScreenTools.smallFontPointSize
            color:            QGroundControl.globalPalette.colorGrey
            text: qsTr("No video FEC here: the ground station never transmits video " +
                       "(gs_video is receive-only), so those values would have no effect.")
        }

        RowLayout {
            spacing: ScreenTools.defaultFontPixelWidth
            QGCButton {
                text:      qsTr("Try Live (reverts in 30 s)")
                enabled:   !_busy && _relayLoaded
                onClicked: _tryLive("relay")
            }
            QGCButton {
                text:      qsTr("Save to Relay Config")
                enabled:   !_busy && _relayLoaded
                onClicked: _save("relay")
            }
            QGCButton {
                text:      qsTr("Read Live Radio")
                enabled:   !_busy
                onClicked: _dispatch(Pxlabs.relay.wfbCfgRadioGet())
            }
        }
    }

    // -----------------------------------------------------------------------
    // Channel / bandwidth — the only settings that must match both ends
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
                id:             bwCombo
                enabled:        _secondaryOk
                model:          [ "20", "40" ]
                sizeToContents: true
            }

            QGCButton {
                text:      qsTr("Apply to BOTH Ends")
                enabled:   !_busy && _secondaryOk && _droneLoaded && _relayLoaded
                onClicked: _applyDanger()
            }
        }
    }

    // -----------------------------------------------------------------------
    // Confirmation + restore
    // -----------------------------------------------------------------------
    SettingsGroupLayout {
        Layout.fillWidth: true
        heading: qsTr("Actions")

        RowLayout {
            spacing: ScreenTools.defaultFontPixelWidth
            QGCButton {
                text:      qsTr("Restore Default (Drone)")
                enabled:   !_busy
                onClicked: { restoreConfirm.which = "drone"; restoreConfirm.visible = true }
            }
            QGCButton {
                text:      qsTr("Restore Default (Relay)")
                enabled:   !_busy
                onClicked: { restoreConfirm.which = "relay"; restoreConfirm.visible = true }
            }
            QGCButton {
                text:      qsTr("Clear Output")
                onClicked: outputArea.text = ""
            }
        }

        ColumnLayout {
            id:      confirmBox
            visible: false
            Layout.fillWidth: true

            property string which:      "drone"
            property bool   live:       false
            property bool   danger:     false
            property string paramsText: ""
            property string params:     ""
            property int    stbc:       0
            property int    ldpc:       0
            property int    mcs:        0

            QGCLabel {
                Layout.fillWidth: true
                wrapMode:         Text.WordWrap
                color:            confirmBox.danger ? QGroundControl.globalPalette.colorRed
                                                    : QGroundControl.globalPalette.colorOrange
                text: (confirmBox.danger ? qsTr("DANGER (channel/bandwidth) → BOTH ends: ")
                                         : confirmBox.live
                                           ? qsTr("Try live on %1 (auto-reverts in 30 s): ").arg(confirmBox.which)
                                           : qsTr("Save to %1 config: ").arg(confirmBox.which))
                      + confirmBox.paramsText
            }

            RowLayout {
                spacing: ScreenTools.defaultFontPixelWidth
                QGCButton {
                    text: qsTr("Yes — Proceed (watchdog-guarded)")
                    onClicked: {
                        confirmBox.visible = false
                        var node = confirmBox.which === "relay" ? Pxlabs.relay : Pxlabs.companion

                        if (confirmBox.live) {
                            _dispatch(node.wfbCfgRadioSet(confirmBox.stbc, confirmBox.ldpc,
                                                          confirmBox.mcs, -1, 30))
                            return
                        }

                        var req = confirmBox.danger
                                ? _dispatch(Pxlabs.wfbCfgSetBoth(confirmBox.params, true, 120))
                                : _dispatch(node.wfbCfgSet(confirmBox.params, false, 60))

                        // Exit 0 == confirmed & kept — fold the applied values into
                        // that side's baseline so the next diff starts from the device.
                        var applied = confirmBox.params
                        var which   = confirmBox.which
                        req.succeeded.connect(function() {
                            var parts = applied.split(",")
                            function fold(base) {
                                var nl = {}
                                for (var k in base) nl[k] = base[k]
                                for (var i = 0; i < parts.length; i++) {
                                    var kv = parts[i].split("=")
                                    if (kv.length === 2) nl[kv[0]] = kv[1]
                                }
                                return nl
                            }
                            if (which === "drone" || which === "both") _drone = fold(_drone)
                            if (which === "relay" || which === "both") _relay = fold(_relay)
                        })
                    }
                }
                QGCButton {
                    text:      qsTr("Cancel")
                    onClicked: confirmBox.visible = false
                }
            }
        }

        ColumnLayout {
            id:      restoreConfirm
            visible: false
            Layout.fillWidth: true

            property string which: "drone"

            QGCLabel {
                text:  qsTr("Restore factory-default wifibroadcast.cfg on %1?").arg(restoreConfirm.which)
                color: QGroundControl.globalPalette.colorOrange
            }
            RowLayout {
                spacing: ScreenTools.defaultFontPixelWidth
                QGCButton {
                    text: qsTr("Yes — Restore Default")
                    onClicked: {
                        restoreConfirm.visible = false
                        var node = restoreConfirm.which === "relay" ? Pxlabs.relay : Pxlabs.companion
                        _dispatch(node.wfbCfgRestoreDefault(60))
                    }
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
