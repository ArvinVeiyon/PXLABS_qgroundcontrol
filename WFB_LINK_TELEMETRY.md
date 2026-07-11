# WFB-NG Link Telemetry — Reference & Tuning Guide

> For the **G-Control RF backbone**. Everything the wireless link reports about itself,
> what each number means, how to use it to debug and fine-tune the RF, and what we can
> predict before things go wrong.
>
> **Verified against the LIVE relay (vind-rly) on 2026-07-11** — 5 s capture of the real
> JSON API on port 8103. Schema below is the actual wire format, not documentation guesswork.
> wfb-ng version: `dev/master`, profile `gs`, **cluster mode**.

---

## 00 · What this is

WFB-NG already measures the health of every radio link and publishes it as structured data —
the same data `wfb-cli gs` prints. Instead of scraping that text, we read the official JSON feed
directly into a monitor app (standalone first, merged into G-Control later). This doc is the map
of that data: the feed, the fields, the meanings, and the early-warning signals.

> **One idea to hold onto:** the radio link is the backbone of the whole system. Every glitch,
> dropout, and range limit shows up first as a change in these numbers — usually *seconds before*
> you'd notice it in the video. Reading them well is how you tune the link instead of guessing.

---

## 01 · Where the data lives — CONFIRMED on the relay

| Port | Name | Format | Status on vind-rly |
|------|------|--------|--------------------|
| **8003** | `stats_port` (gs) | MessagePack (binary) | LISTENING — used by `wfb-cli gs` |
| **8103** | `api_port` (gs) | **JSON lines** over TCP | LISTENING — **our feed** |
| 8203 / 8303 | cluster `api/stats_port` | — | internal cluster manager ports |
| 8002 / 8102 | drone profile ports | — | on the air unit, not the relay |

Key facts confirmed live:

- **Both ports listen on `0.0.0.0`** → the PC can connect **directly to `10.5.6.101:8103`**
  over the P2P link. **No SSH tunnel needed.**
- One JSON object per line, ~1 message per stream per second (`log_interval = 1000`).
- On connect, the server first sends a **`settings` message** — a full config dump
  (see §03). The app can auto-discover channel, FEC, cluster nodes, everything.
- Live config: **channel 161**, 5805 MHz, 20 MHz BW, MCS 1, region `BO`, txpower 3000.

---

## 02 · How it reaches the screen

```
DRONE (air unit)                 GROUND (cluster)                      PC
 FC / camera
    │                 ┌─ relay RPi5 (vind-rly, 10.5.7.100)
 wlan (monitor mode)  │    wlan wlx00c0cab6db3b  → ant 0/1
    │                 │
    └──── RF ────────►│                                wfb aggregator (on relay)
                      │                                     │
                      └─ CPE610 (OpenWrt, 10.5.7.102)       │
                           phy0-mon0 → ant 0/1         JSON API :8103 ──── direct TCP ───► monitor app
                           (also current TX node!)          └──► wfb-cli gs
```

Cluster mode: **two RX nodes** feed the aggregator, so antenna stats show 4 antennas
(2 per node). The TX selector picks the best node for uplink — in the live capture the
**CPE610 was carrying the uplink**, not the relay's own card.

We add a **second reader** to a feed that already exists. Nothing about the RF path changes —
zero risk to the live link.

---

## 03 · The real JSON (from live capture)

One message per line. Types seen: `settings` (once, on connect), then per second:
`rx` × {video, mavlink, tunnel} and `tx` × {mavlink, tunnel}.

### `settings` message — sent once on connect

```jsonc
{
  "type": "settings",
  "profile": "gs",
  "is_cluster": true,
  "settings": {
    "common": { "wifi_channel": 161, "wifi_region": "BO", "wifi_txpower": 3000,
                "log_interval": 1000, "temp_overheat_warning": 60, ... },
    "cluster": { "nodes": { "127.0.0.1": {...}, "10.5.7.102": {...} },
                 "server_address": "10.5.7.100", ... },
    "gs": { "streams": [ {"name": "video", "stream_rx": 0, ...},
                         {"name": "mavlink", ...}, {"name": "tunnel", ...} ] }
  }
}
```

Use this to auto-configure the panel — no hardcoding of channel/streams/nodes.

### `rx` message — the downlink (real sample, video stream)

```jsonc
// every packet counter is a pair: [this_second, running_total]
{
  "type": "rx",
  "timestamp": 1774564960.32,
  "id": "video rx",
  "tx_wlan": 2820279101292544,      // which node's wlan the drone TX selected (= ant_id >> 8)
  "packets": {
    "all":       [507, 706705],     // received this second
    "all_bytes": [701452, 1003240348],
    "dec_ok":    [507, 706699],     // decrypted OK
    "dec_err":   [0, 6],            // decrypt/decode errors (key/config issue, not RF)
    "fec_rec":   [0, 344],          // ★ rebuilt by FEC — "link is straining"
    "lost":      [0, 0],            // ★★ unrecoverable loss — glitches happen HERE
    "bad":       [0, 0],            // corrupt — usually interference
    "out":       [176, 240691],     // delivered upward (post FEC/dedup) — the good ones
    "out_bytes": [229403, 327090807]
  },
  "session": { "fec_type": "VDM_RS", "fec_k": 8, "fec_n": 12, "epoch": 0 },
  "rx_ant_stats": [                 // ⚠ a LIST of objects (not a dict) — one per antenna
    { "ant": 721991441340956673,    // encodes node+wlan+antenna, see decode below
      "freq": 5805, "mcs": 1, "bw": 20, "pkt_recv": 264,
      "rssi_min": -18, "rssi_avg": -15, "rssi_max": -12,
      "snr_min": 19,  "snr_avg": 24,  "snr_max": 30 },
    { "ant": 721991441340956672, "...": "relay ant 0" },
    { "ant": 721991449930891265,    // CPE610 antenna — NOTE the quirk below
      "freq": 5805, "mcs": 1, "bw": 20, "pkt_recv": 243,
      "rssi_min": 22, "rssi_avg": 24, "rssi_max": 47,
      "snr_min": 0, "snr_avg": 0, "snr_max": 0 },
    { "ant": 721991449930891264, "...": "CPE610 ant 0" }
  ]
}
```

**Antenna ID decode** (verified):

```python
node_ip  = socket.inet_ntoa(struct.pack('!I', ant >> 32))   # 10.5.7.100 relay / 10.5.7.102 CPE610
wlan_idx = (ant >> 8) & 0xFFFFFF
ant_idx  = ant & 0xFF                                        # 255 = wlan-level (tx)
```

> **CPE610 quirk (important):** the OpenWrt node reports `snr = 0` (driver doesn't provide it)
> and RSSI on a **positive scale** (22…52) — not comparable to the relay card's dBm (−18…−12).
> The panel must treat antenna stats **per node**: dBm + SNR for the relay card, raw
> signal-index for the CPE610. Never compare RSSI across nodes directly.

### `tx` message — the uplink (real sample)

```jsonc
{
  "type": "tx",
  "timestamp": 1774564960.33,
  "id": "mavlink tx",
  "packets": {
    "incoming":       [1, 2365],    // packets handed to WFB for uplink
    "incoming_bytes": [47, 65882],
    "injected":       [4, 8114],    // actually pushed onto the air (> incoming due to FEC)
    "injected_bytes": [313, 485978],
    "dropped":        [0, 0],       // couldn't inject — airtime/driver pressure
    "truncated":      [0, 0],
    "fec_timeouts":   [0, 0]
  },
  "rf_temperature": {},             // empty dict when adapter doesn't report temp
  "tx_ant_stats": [                 // LIST — one per TX wlan
    { "ant": 721991449930891519,    // node 10.5.7.102, ant_idx 255 → CPE610 carries uplink
      "pkt_sent": 4, "pkt_drop": 0,
      "lat_min": 6, "lat_avg": 9, "lat_max": 17 }   // injection latency, µs
  ]
}
```

### Live per-stream FEC (predictors depend on these!)

| Stream | fec_k / fec_n | Spare packets per block |
|--------|---------------|--------------------------|
| video | **8 / 12** | 4 |
| mavlink | **1 / 3** | 2 (heavy redundancy) |
| tunnel | **2 / 4** | 2 |

`fec_type` is `VDM_RS` (Reed-Solomon variant).

---

## 04 · Field reference

Every field that matters, in plain language. ★ = watch these most.

| Field | Lives in | What it means |
|-------|----------|---------------|
| `all` | rx packets | Total packets received this second. Raw inflow. |
| `dec_ok` / `dec_err` | rx packets | Decrypt results. `dec_err` > 0 usually means key/config mismatch, not RF. |
| `out` | rx packets | Packets delivered upward (video/MAVLink) after FEC + dedup. The "good" throughput. |
| `fec_rec` ★ | rx packets | Arrived corrupt/missing but rebuilt by FEC. Rising = straining but holding. |
| `lost` ★★ | rx packets | Packets FEC could **not** rebuild → glitches / telemetry gaps. Should sit at 0. |
| `bad` | rx packets | Corrupt/undecodable frames. High with steady signal = interference. |
| `rssi_avg` | rx_ant_stats | Signal strength per antenna. dBm on the relay card; positive index on CPE610. |
| `snr_avg` ★ | rx_ant_stats | Signal-to-noise (dB) — your real headroom. Only the relay card reports it. |
| `pkt_recv` | rx_ant_stats | Packets that antenna pulled in. Compare within a node to judge diversity. |
| `fec_k / fec_n` | session | FEC ratio per stream (see table above). |
| `mcs` / `bw` / `freq` | rx_ant_stats | Modulation, bandwidth, frequency the packets arrived with. |
| `tx_wlan` | rx top-level | Which node's wlan the drone-side TX selector currently favors (= `ant >> 8`). |
| `incoming` / `injected` | tx packets | Handed to WFB vs actually transmitted (injected > incoming due to FEC spares). |
| `dropped` | tx packets | Uplink packets that couldn't be sent — airtime saturation or driver limit. |
| `lat_avg` | tx_ant_stats | Injection latency (µs). Rising = the adapter is backing up. |
| `rf_temperature` | tx | Adapter temp dict — empty `{}` if the driver doesn't report it (ours doesn't). |

---

## 05 · Symptom → cause → fix

The debugging loop: something looks wrong → glance at the panel → the field points to the knob.

| You see | It means | Tuning action |
|---------|----------|---------------|
| `lost` > 0 **(critical)** | Real data loss — glitches/dropouts now. | Lower MCS/bitrate, raise FEC redundancy, or reduce range. |
| `fec_rec` climbing **(warning)** | Link degrading, FEC still saving you. | Act before it hits `lost`: more FEC, lower MCS, more TX power. |
| `snr_avg` falling (relay card) | Shrinking headroom above the decode floor. | Change channel (noise) or raise TX power (distance). |
| One antenna's `pkt_recv` far below its pair | Broken diversity within that node. | Check connector/cable, reposition or replace that antenna. |
| `bad` high, RSSI steady | Interference, not distance. | Change channel / region; look for co-channel users. |
| `out` bitrate below target | MCS too low or FEC overhead too high. | Raise MCS if SNR allows; tune the k/n ratio. |
| `dropped` (tx) rising | Uplink airtime saturated. | Reduce uplink rate; check for RF congestion. |
| `dec_err` rising | Key/config mismatch (not RF). | Check gs.key / epoch match between air and ground. |
| `tx_wlan` flapping between nodes | TX selector can't decide — both nodes marginal. | Improve placement of one node; check `tx_sel_rssi_delta`. |

---

## 06 · What we can predict

**Honest framing:** this isn't AI magic — it's watching *trends and physics thresholds* at 1 Hz.
Every predictor is plain arithmetic on the fields above, and every one is **explainable**
("SNR is 3 dB from the floor and dropping"). Ordered easiest → most valuable.

**1. "Video is about to glitch" — FEC headroom.**
Per stream: video can rebuild **4** packets per 12-packet block, mavlink 2/3, tunnel 2/4.
If `fec_rec`/s keeps rising while `lost` is still 0, you're eating the safety margin. Warn
*before* the first glitch — the single most useful signal.
`pressure = fec_rec_rate / all_rate → warn when sustained above baseline`

**2. "Approaching the link cliff" — SNR margin.**
Each MCS needs a minimum SNR to decode (MCS1/20MHz ≈ 5 dB floor). Live SNR was ~24 dB avg →
~19 dB of headroom. Track the slope of `snr_avg` (relay card only) to estimate seconds-to-cliff.
Falling SNR *and* rising `fec_rec` together = high-confidence alert.
`margin = snr_avg − mcs_floor · eta = margin ÷ (−slope)`

**3. "An antenna is failing."**
Compare `pkt_recv` and RSSI **within each node's antenna pair** (cross-node comparison is
invalid — different RSSI scales). A steadily diverging pair predicts a dying connector/cable.
`spread = |ant0 − ant1| within node → flag on sustained divergence`

**4. "Time / range to link loss."**
Log relay-card `rssi_avg` over time (pair with GPS distance later). Extrapolate the downward
slope to the minimum usable RSSI for a rough range budget.
`eta = (rssi_avg − rssi_min_usable) ÷ (−slope)`

**5. "Interference is appearing."**
Rising `bad` (or `fec_rec`) with *stable* RSSI means noise, not distance. Distinguishes a
channel problem (change channel) from a range problem (more power / closer).

> **Later, if you want:** once these deterministic signals are logging, the same features
> (SNR slope, fec_rec rate, antenna spread) are exactly what a small model would use to predict
> "freeze in next N seconds." Start explainable; add ML only if the simple rules leave
> something on the table.

---

## 07 · The monitor app it feeds

Standalone PyQt5 app first (clean `client / model / widgets` split), merged into G-Control later.
QGC gets the lite path (relay-side `RADIO_STATUS` injection) separately if wanted.

- **Diversity strip** — RSSI/SNR + pkt/s per antenna, **grouped by node** (relay vs CPE610).
- **FEC health graph** — `fec_rec` vs `lost` over a rolling window. Degradation early-warning, drawn.
- **Packet & bitrate readout** — out/s, Mbit/s, fec_rec/s, lost/s, bad/s, per stream.
- **Link-state summary** — one GOOD / WARN / CRITICAL badge from the predictor thresholds.
- **TX node indicator** — which node currently carries the uplink (from `tx_wlan` / `tx_ant_stats`).
- **Rolling history buffer** — last N seconds retained, to catch a transient dropout *after* it happened.
- **Separate downlink / uplink** — video (rx) and RC/MAVLink (tx) tune differently → own readouts.

---

## 08 · Relay verification — DONE 2026-07-11

- [x] Port 8103 enabled and listening on `0.0.0.0` → **direct TCP from PC works, no tunnel**.
- [x] Live JSON captured (5 s): streams = video/mavlink/tunnel; FEC = 8/12, 1/3, 2/4; `VDM_RS`.
- [x] Cluster confirmed: relay 10.5.7.100 (`wlx00c0cab6db3b`) + CPE610 10.5.7.102 (`phy0-mon0`).
- [x] Antenna-ID decode verified: `ip = ant>>32`, `wlan = (ant>>8)&0xFFFFFF`, `ant_idx = ant&0xFF`.
- [x] CPE610 quirk documented: `snr=0`, positive RSSI scale — handle per node.
- [ ] Open: locate whatever already injects an RSSI into QGC telemetry (likely a `RADIO_STATUS`
      translator on the relay — the partial "native QGC" path). Check mavlink.router config /
      wfb `mavlink_err_rate` (it was `true` in settings — wfb-ng itself can inject err rate!).

> Note: `mavlink_err_rate = true` in the live settings — wfb-ng's mavlink profile can inject
> link-quality info into the MAVLink stream itself. **This is probably the mystery QGC RSSI.**

---

*Built for the G-Control / PXLabs RF backbone. See also: `ARCHITECTURE.md`, `BUG_FIX_companion_relay.md`.*
