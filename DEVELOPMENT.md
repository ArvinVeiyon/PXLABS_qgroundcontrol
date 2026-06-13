# G-Control — Development Document

Full architecture, design decisions, and development history.
For a raw file-by-file change log see `PXLABS_CHANGES.md`.

---

## 1. What G-Control Is

**G-Control** is a customised build of QGroundControl v5.0.8 for the **Vind-Roz** drone system.

QGC provides the standard GCS layer: MAVLink telemetry, HUD, mission planning, parameter tuning, video display.
G-Control adds a second operational layer on top: **remote management of the companion computer and relay station**
directly from within the GCS window — camera switching, service control, WFB mode switching, SSH terminals,
system power management — without the operator ever needing a separate terminal or app.

Everything added is strictly **additive**. No native QGC file is deleted or restructured.
All PXLABS code lives in new files, with two minimal additive hooks into native files
(`QGCApplication.cc` for singleton registration, `FlyViewToolBar.qml` for toolbar chips).

| | |
|---|---|
| Base | QGroundControl v5.0.8 (tag `qgc-v5.0.8-base`) |
| Dev branch | `PXLABS-v2.1-integration` |
| GitHub | `https://github.com/ArvinVeiyon/PXLABS_qgroundcontrol` |
| Build output | `E:\qgc-pxlabs\build_clean\Release\G-Control.exe` |
| Installer | `installer\G-Control-Setup-v<version>.exe` |

---

## 2. Full System — Hardware & Network

### 2.1 Companion Computer — Vind-Roz

| Item | Detail |
|------|--------|
| Board | Raspberry Pi 5 (8 GB) |
| OS | Ubuntu 24.04 LTS |
| ROS2 | Jazzy |
| Flight Controller | Custom Pixhawk 6X-RT (NXP i.MX RT1176), PX4 v1.16.0-rc1 |
| WFB NIC | rtl88x2eu (`wlx00c0caa578a9` — auto-detected via `wfb-nics`) |
| System version | `sid.conf` v1.3.7 (2026-03-08) |
| SSH (via relay) | `roz@10.5.6.101:2222` |
| SSH (direct WFB) | `roz@10.5.5.87:22` |

**UART Map (FC ↔ RPi5):**

| Port | Role | Baud |
|------|------|------|
| `/dev/ttyAMA0` | FC MAVLink → mavlink-router | 921600 |
| `/dev/ttyAMA2` | TFmini Plus lidar | 115200 |
| `/dev/ttyAMA4` | FC uXRCE-DDS → MicroXRCEAgent | 921600 |

**Cameras:**

| Device | Camera | udev Rule |
|--------|--------|-----------|
| `/dev/video0` | Waveshare AF (front) — VendorID `0ede:8093` | symlinked by `99-usb-cameras.rules` |
| `/dev/video2` | See3CAM_CU135 (bottom) — VendorID `2560:c1d1` | symlinked by `99-usb-cameras.rules` |
| `/dev/video3` | Optical flow camera | — |

Camera device names are **stable** via udev — always `/dev/video0` and `/dev/video2` regardless of plug order.

**Companion Services:**

| Service | Function |
|---------|---------|
| `wifibroadcast@drone` | WFB-NG drone profile — 3 streams: video TX, MAVLink TX/RX, tunnel TX/RX |
| `mavlink.router` | Routes MAVLink: FC UART → WFB-NG UDP (127.0.0.1:14550) |
| `microxrce-agent` | uXRCE-DDS bridge: FC UART ↔ ROS2 DDS domain (RMW) |
| `vision_streaming` | ROS2 node: reads `/etc/vision_streaming.conf`, runs FFmpeg → RTP → `127.0.0.1:5602` |
| `rc_control_node` | ROS2 node: RC CH9 PWM → camera switch commands to vision_config_manager |
| `tfmini` | ROS2 node: TFmini Plus lidar → `/fmu/in/distance_sensor` |
| `ros2_px4_translation_node` | ROS2 ↔ PX4 uORB message translation |
| `ros2_external_node_reg` | Rover external nodes (`rov_ext`, `rov_collision_stop`) |
| `block-traffic` | iptables: blocks DDS multicast (239.255.0.1, ports 7400–7500) on `drone-wfb` interface — prevents ROS2 topics flooding WFB tunnel |
| `system_files_sync.timer` | Daily: rsync tracked config files → git commit + annotated tag in `codex-work` repo |
| `ollama` | Local LLM server (Claude-on-device, for onboard AI use) |

---

### 2.2 Relay Station — Vind-Rly

| Item | Detail |
|------|--------|
| Board | Raspberry Pi 5 |
| OS | Ubuntu 24.04 LTS |
| WFB NIC | rtl8812eu (`wlx00c0cab6db3b`) — fixed in `/etc/default/wifibroadcast` |
| System version | `sid.conf` v1.0 (2026-03-15) |
| SSH | `vind-admin@10.5.6.101:22` (P2P) or `vind-admin@10.5.5.77` (WFB tunnel) |

**Network Interfaces:**

| Interface | IP | Role |
|-----------|----|------|
| `eth0` | — | Ethernet to CPE610 OpenWrt node (cluster mode) |
| `wlan0` | — | Onboard WiFi — P2P group owner |
| `p2p-wlan0-0` | `10.5.6.101/24` | P2P group — GCS connects here |
| `wlx00c0cab6db3b` | — | WFB-NG RF adapter — air link to drone |
| `gs-wfb` | `10.5.5.77/24` | WFB-NG tunnel interface (drone end: `10.5.5.87/24`) |

**GCS (G-Control Windows PC):** static IP `10.5.6.50` on the P2P LAN.

**Relay Services:**

| Service | Function |
|---------|---------|
| `wifibroadcast@gs` | WFB-NG ground station — standalone mode (active default) |
| `wifibroadcast-cluster@gs` | WFB-NG cluster mode — uses CPE610 at `10.5.7.102` as second node |
| `mavlink.router` | Routes MAVLink: WFB-NG UDP (0.0.0.0:14560) → QGC (10.5.6.50:14550) + tracker (127.0.0.1:14551) |
| `ssh-tunnel-to-companion` | `autossh -L 0.0.0.0:2222:10.5.5.87:22 roz@10.5.5.87` — exposes drone SSH on relay port 2222 |
| `relay_files_sync.timer` | Boot + daily: rsync tracked config files → git commit in `codex-relay` repo |
| `mediamtx` | DISABLED (2026-03-15) — was RTSP video relay, replaced by direct WFB-NG GS endpoint |
| `isc-dhcp-server` | DISABLED (2026-03-15) — GCS uses static IP, DHCP not needed |

---

### 2.3 Full Network + Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│  G-Control.exe  (Windows PC — 10.5.6.50)                               │
│                                                                          │
│  GStreamer ◄── UDP :5600 (H264 video)                                   │
│  MAVLink   ◄── UDP :14550 (telemetry)                                   │
│  SSH ──────────────────────────────────► :22 relay, :2222 companion     │
└────────────────────────┬────────────────────────────────────────────────┘
                         │  Wi-Fi P2P  (10.5.6.0/24)
┌────────────────────────▼────────────────────────────────────────────────┐
│  Vind-Rly (Relay Station — 10.5.6.101 P2P / 10.5.5.77 WFB tunnel)     │
│                                                                          │
│  wifibroadcast@gs                                                        │
│    ├─ video stream  ◄── WFB-NG rx (wlx00c0cab6db3b, ch157) ──► :5600   │
│    ├─ mavlink       ◄──► WFB-NG    ──► local mavlink-router :14560      │
│    └─ tunnel        ◄──► WFB-NG    ──► gs-wfb (10.5.5.77)             │
│                                                                          │
│  mavlink-router                                                          │
│    ├─ input:  0.0.0.0:14560  (from WFB-NG GS mavlink peer)              │
│    ├─ output: 10.5.6.50:14550 (→ G-Control QGC)                        │
│    └─ output: 127.0.0.1:14551 (→ antenna tracker, future)              │
│                                                                          │
│  ssh-tunnel:  0.0.0.0:2222  ──────────────────► 10.5.5.87:22           │
└────────────────────────┬────────────────────────────────────────────────┘
                         │  WFB-NG RF link  (5 GHz ch157, MCS1, 20 MHz)
                         │  rtl8812eu ◄──────────────────► rtl88x2eu
┌────────────────────────▼────────────────────────────────────────────────┐
│  Vind-Roz (Companion — 10.5.5.87 WFB / 10.5.5.87:22 SSH)              │
│                                                                          │
│  wifibroadcast@drone                                                     │
│    ├─ video  TX ──► WFB-NG  (from vision_streaming → :5602)             │
│    ├─ mavlink RX ◄──► WFB-NG  (to/from mavlink-router :14550)           │
│    └─ tunnel  RX ◄──► WFB-NG  (drone-wfb 10.5.5.87 ◄──► gs-wfb 10.5.5.77)
│                                                                          │
│  vision_streaming (ROS2)                                                 │
│    ├─ reads /etc/vision_streaming.conf                                   │
│    └─ FFmpeg /dev/video0 → H264 RTP → 127.0.0.1:5602                   │
│                                                                          │
│  mavlink-router                                                          │
│    ├─ /dev/ttyAMA0:921600  (FC MAVLink)                                  │
│    └─ 127.0.0.1:14550      (→ WFB-NG drone mavlink)                     │
│                                                                          │
│  microxrce-agent: /dev/ttyAMA4:921600 ◄──► ROS2 DDS                    │
│  block-traffic:   DROP DDS multicast on drone-wfb (prevents ROS2        │
│                   topics from flooding WFB tunnel bandwidth)             │
│                                                                          │
│  Cameras: /dev/video0 (front Waveshare AF)                               │
│            /dev/video2 (bottom See3CAM_CU135)                            │
│            /dev/video3 (optical flow)                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

### 2.4 WFB-NG Link Configuration

Both drone and relay use `/etc/wifibroadcast.cfg`. Key parameters:

| Parameter | Value | Notes |
|-----------|-------|-------|
| `wifi_channel` | 157 | 5 GHz |
| `wifi_region` | `BO` | Allows higher TX power |
| `wifi_txpower` | 3000 (= 30 dBm × 100) | rtl8812eu |
| `mcs_index` | 1 | BPSK 1/2 — robust, ~7 Mbps |
| `bandwidth` | 20 MHz | All streams |
| `stbc` | 1 | Space-time block coding enabled |
| `ldpc` | 1 | Low-density parity-check enabled |
| `temp_overheat_warning` | 60°C | Air-TX chip threshold shown in G-Control toolbar |

**3 WFB-NG streams (drone ↔ relay):**

| Stream | TX side | RX side | FEC | Purpose |
|--------|---------|---------|-----|---------|
| `video` | drone (stream 0x00) | relay | k=8, n=12 | H264 video downlink |
| `mavlink` | both (0x10/0x90) | both | k=1, n=2(drone)/n=3(relay) | MAVLink uplink + downlink |
| `tunnel` | both (0xa0/0x20) | both | k=2, n=4 | SSH tunnel (drone-wfb ↔ gs-wfb) |

**Keys:** `/etc/drone.key` (on both) + `/etc/gs.key` (on both) — symmetric keypair.
Drone uses `drone.key` as keypair; GS uses `gs.key` as keypair.

**WFB NIC auto-detection (companion):**
`/etc/default/wifibroadcast` sets `WFB_NICS="$(wfb-nics)"` — automatically picks up
the 8812au/8812eu card regardless of interface name.

**Relay NIC is hardcoded:**
`/etc/default/wifibroadcast` on relay: `WFB_NICS="wlx00c0cab6db3b"` (rtl8812eu, fixed).

---

### 2.5 SSH Path to Companion

G-Control always connects to the companion via the relay's SSH tunnel:

```
G-Control (10.5.6.50)
  └─► SSH :2222 on relay (10.5.6.101)
       └─► autossh forwards to companion (10.5.5.87:22)
            └─► roz@companion
```

The tunnel uses a key (`/home/vind-admin/.ssh/id_rsa`) — passwordless from relay to companion.
G-Control supplies `roz`'s password, which is used for the SSH login and for `sudo` on the companion.

**Fallback (direct WFB, on-site only):**
If relay tunnel is unreachable, `pxlabs_cli` falls back to `10.5.5.87:22` (direct WFB tunnel IP).
This only works when the operator is on-site with the drone on the same WFB link.

---

## 3. G-Control Architecture

### 3.1 Layers

```
┌─────────────────────────────────────────────────────────────────┐
│                        G-Control.exe (Windows)                  │
│                                                                  │
│  ┌──────────────────────┐   ┌────────────────────────────────┐  │
│  │  QGC Native Layer    │   │  PXLABS Layer (additive)       │  │
│  │  (unchanged)         │   │                                │  │
│  │  MAVLink telemetry   │   │  Settings pages:               │  │
│  │  HUD / instruments   │   │    ConnectionControl.qml       │  │
│  │  Mission planning    │   │    PXLABSSettings.qml          │  │
│  │  Vehicle params      │   │    CompanionControl.qml        │  │
│  │  GStreamer video      │   │    RelayControl.qml            │  │
│  │  Native capture      │   │                                │  │
│  │                      │   │  FlyView additions:            │  │
│  │                      │   │    FlyViewCustomLayer.qml      │  │
│  │                      │   │    FlyViewToolBar.qml (chips)  │  │
│  └──────────────────────┘   └──────────────┬─────────────────┘  │
│                                             │                    │
│                              PXLABSCommandRunner.cc              │
│                              (C++ QProcess singleton)            │
└─────────────────────────────────┬───────────────────────────────┘
                                  │ subprocess per command
                         ┌────────▼──────────┐
                         │  pxlabs_cli.exe   │
                         │  (PyInstaller)    │
                         │  paramiko SSH     │
                         └──────┬──────┬─────┘
                                │      │
                  SSH :2222     │      │ SSH :22
             ┌──────────────────▼─┐ ┌──▼──────────────┐
             │  Vind-Roz           │ │  Vind-Rly       │
             │  (Companion RPi5)   │ │  (Relay RPi5)   │
             └────────────────────┘ └─────────────────┘
```

**Layer 1 — QGC Native (untouched):**
Standard QGC. Video arrives as RTP H264 from companion → WFB-NG → relay → GCS UDP :5600,
decoded by GStreamer (d3d11h264dec, no gstlibav needed). MAVLink arrives via relay's
mavlink-router → GCS UDP :14550.

**Layer 2 — PXLABS QML + C++ (all additive):**
All companion/relay management UI. Runs inside the same Qt process. Communicates downward
through `PXLABSRunner` singleton to spawn CLI subprocesses.

**Layer 3 — pxlabs_cli (stateless subprocess):**
Python SSH bridge compiled to a standalone exe. One process per command. Opens a fresh
paramiko connection, executes one remote command, streams stdout/stderr through QProcess
pipes, exits. No persistent connection held between commands.

---

### 3.2 PXLABSCommandRunner — C++ Singleton

**Files:** `src/Utilities/PXLABSCommandRunner.h/.cc`
**Registered:** `src/QGCApplication.cc` → `qmlRegisterSingletonType<PXLABSCommandRunner>(...)`
**QML access:** `import QGroundControl.PXLABS` → `PXLABSRunner`

The only C++ code added. A thin QProcess wrapper with three responsibilities:

**1. Launch the CLI:**
- Reads `cliPath` and `pythonPath` from `QSettings`.
- If `cliPath` ends with `.exe` → runs directly (installed mode, no Python needed).
- If `cliPath` ends with `.py` → prepends `pythonPath` (developer mode, source script).
- Default: `<appDir>/tools/pxlabs_cli.exe`.

**2. Stream output:**
- Both `readyReadStandardOutput` and `readyReadStandardError` accumulate into `_lastOutput`
  and emit `outputReady(text)`. Stderr is included in the same stream intentionally —
  the CLI mixes status messages into stderr for QProcess visibility.

**3. Signal completion:**
- `_onFinished` drains any remaining buffered bytes before emitting `commandFinished(exitCode)`.
  Critical: QProcess buffers can flush *after* the `finished` signal fires. Draining first
  prevents QML from missing the last chunk of output.

**Constraint:** Only one command at a time (`_running` guard).
**Broadcast:** `outputReady` and `commandFinished` go to ALL pages with a `Connections { target: PXLABSRunner }` block — each page must use a boolean flag to claim its own responses (see §3.4).

**QML API:**
```qml
import QGroundControl.PXLABS

PXLABSRunner.run("companion front-switch")   // args only — runner prepends cli path
PXLABSRunner.abort()                         // kills subprocess
PXLABSRunner.running                         // bool
PXLABSRunner.lastOutput                      // cumulative stdout+stderr
// Signals:
onOutputReady(text)          // fires per output chunk
onCommandFinished(exitCode)  // 0 = success, after drain
onCommandFailed(errorText)   // process didn't start / crashed
```

---

### 3.3 pxlabs_cli — SSH Bridge

**Source:** `tools/pxlabs_cli.py` → **Compiled to:** `build_clean\Release\tools\pxlabs_cli.exe`

Stateless — one subprocess per command. Every call opens a fresh paramiko SSH session.

#### Config path resolution

```python
# PyInstaller frozen: __file__ → temp _MEI* dir (wrong). Use sys.executable instead.
if getattr(sys, "frozen", False):
    ROOT = Path(sys.executable).resolve().parents[1]   # real install dir
else:
    ROOT = Path(__file__).resolve().parents[1]          # dev: repo root
CONFIG_PATH = ROOT / "config" / "ssh_config.json"
```

Config JSON stores: companion IP/port/user, relay IP/port/user.
Passwords are **not** in the JSON — stored in Windows keyring (service: `"Drone-Control"`, account: username).
This means passwords survive reinstall and never appear in plaintext files.

#### Companion connection selection

```python
def pick_companion_host(cfg):
    # Primary: relay tunnel (10.5.6.101:2222 → relay → drone)
    if is_reachable(primary_ip, primary_port):   # 5 s TCP socket test
        return primary_ip, primary_port
    # Fallback: direct WFB (10.5.5.87:22, on-site only)
    if secondary_ip and is_reachable(secondary_ip, secondary_port):
        return secondary_ip, secondary_port
    return primary_ip, primary_port   # return primary regardless, let SSH fail with real error
```

#### sudo password feeding (security)

```python
def _sudo_wrap(command, password):
    # printf instead of echo — echo exposes password in `ps aux` on remote host
    if command.startswith("sudo "):
        pw = password.replace("'", "'\"'\"'")
        return f"printf '%s\\n' '{pw}' | sudo -S {command[5:]}"
    return command
```

All root commands use `sudo -S` (read from stdin). The companion's `sudoers` grants `roz`
passwordless access to `systemctl`, `journalctl`, `tee`, `cp`, `apt` — but `vision_config_manager`
and other scripts still require password-fed sudo.

#### Structured output formats (parsed by G-Control QML)

| Format | Example | Parsed by |
|--------|---------|-----------|
| Reachability | `COMPANION:reachable` / `RELAY:unreachable` | FlyViewToolBar — connection status chips |
| WFB mode | `SA:active` / `CA:inactive` | FlyViewCustomLayer — WFB mode detection |

All other output is raw text displayed in the relevant QML page `TextArea`.

---

### 3.4 What CLI Commands Actually Do on the Remote System

#### Camera switching → vision_config_manager

`vision_config_manager` is a Python script at `/usr/local/bin/vision_config_manager` on the companion.
It manages `/etc/vision_streaming.conf` and controls `vision_streaming.service`.

**Config file (`/etc/vision_streaming.conf`):**
```ini
[general]
rtp_ip = 127.0.0.1
rtp_port = 5602

[primary]
camera_name = /dev/video0
resolution = 1280x720
bitrate = 3000K
fps = 60
format = MJPG

[secondary]          # only present during split/PiP
camera_name = /dev/video2
resolution = 1280x720
fps = 30
format = MJPG
pip_position = bottom-right
pip_size = 240x180
bitrate = 2000K
```

**How `vision_config_manager` works:**
- **Legacy switch** (positional args): `vision_config_manager /dev/video0` — probes live V4L2
  format without stopping the service (`v4l2-ctl --get-fmt-video`, `--get-parm`), updates
  `[primary]` section, removes `[secondary]` if single device, restarts service.
  Atomic write: writes to `/tmp/vision_streaming.conf` then `sudo cp` to destination.
- **`set-cam-params`**: sets resolution/fps/format in config → restarts service.
- **`list-details`**: returns full camera info (V4L2 formats, current settings, udevadm metadata).

**G-Control → CLI → remote mapping:**

| G-Control action | CLI args | Remote command |
|-----------------|---------|----------------|
| Front camera | `companion front-switch` | `sudo vision_config_manager /dev/video0` |
| Bottom camera | `companion bottom-switch` | `sudo vision_config_manager /dev/video2` |
| Split front→bottom | `companion split-front-bottom` | `sudo vision_config_manager /dev/video0 /dev/video2` |
| Split bottom→front | `companion split-bottom-front` | `sudo vision_config_manager /dev/video2 /dev/video0` |
| Query camera | `companion camera-query --device /dev/video0` | `sudo vision_config_manager list-details /dev/video0` |
| Set params | `companion camera-params --device /dev/video0 --resolution 1920x1080 --fps 60 --format MJPG` | `sudo vision_config_manager set-cam-params /dev/video0 1920x1080 60 --format MJPG` |

Also note: **RC CH9** on the drone triggers camera switching directly via `rc_control_node` (ROS2):
- PWM 1012 → front (`/dev/video0`)
- PWM 1514 → bottom (`/dev/video2`)
- PWM 2014 → split/PiP

RC switching and G-Control switching both call `vision_config_manager` — they are equivalent paths.

#### Air-TX temperature → companion NIC thermal read

The Air-TX chip in the G-Control toolbar shows WFB RF card temperature. Detection chain (3-step):

1. Read `/etc/default/wifibroadcast` to get actual WFB NIC name (e.g. `wlx00c0caa578a9`)
2. Try `wfb-cli drone` — parse output for `XX°C` or `XX C` pattern (WFB-NG built-in temp reporting)
3. Fall back to sysfs: `/sys/class/net/<nic>/device/hwmon*/temp1_input` or similar thermal scan

WFB config sets `temp_overheat_warning = 60` — G-Control uses the same threshold for orange/red colour.

#### WFB mode switching → wfb-rlyctl on relay

`wfb-rlyctl` is a shell script at `/usr/local/sbin/wfb-rlyctl` on the relay.
It controls two WFB-NG operating modes:

**Standalone mode** (default):
- Service: `wifibroadcast@gs.service`
- NIC: `wlx00c0cab6db3b` (single rtl8812eu adapter)
- Command: `sudo wfb-rlyctl use-standalone`

**Cluster mode** (adds OpenWrt CPE610 as second WFB node):
- Service: `wifibroadcast-cluster@gs.service`
- Nodes: relay (`127.0.0.1`) + CPE610 (`10.5.7.102`, iface `phy0-mon0`)
- SSH key: `/home/vind-admin/.ssh/wfb_cluster_ed25519`
- Command: `sudo wfb-rlyctl use-cluster`

**G-Control → CLI → relay mapping:**

| G-Control action | CLI args | Remote command |
|-----------------|---------|----------------|
| Refresh WFB status | `relay wfb refresh` | `wfb-rlyctl status` → outputs `SA:active/inactive` + `CA:active/inactive` |
| Switch to standalone | `relay wfb switch --mode standalone` | `sudo wfb-rlyctl use-standalone` |
| Switch to cluster | `relay wfb switch --mode cluster` | `sudo wfb-rlyctl use-cluster` |
| List NICs | `relay wfb list-nics` | `wfb-rlyctl list-nics` |
| Set NICs | `relay wfb set-nics --nics <iface>` | `sudo wfb-rlyctl set-nics <iface>` — updates `/etc/default/wifibroadcast` + restarts |
| WFB logs | `relay wfb logs` | `journalctl -u wifibroadcast@gs -n 60 --no-pager` |
| View config | `relay wfb view-config` | `cat /etc/wifibroadcast.cfg` |

**WFB mode output parsing in G-Control:**

```qml
// FlyViewCustomLayer.qml — onOutputReady
var saMatch = text.match(/^SA:(\S+)/m)   // SA = Standalone Active
var caMatch = text.match(/^CA:(\S+)/m)   // CA = Cluster Active
if (sa === "active" && ca !== "active")      newMode = "standalone"
else if (ca === "active" && sa !== "active") newMode = "cluster"
else if (sa === "active" && ca === "active") newMode = "standalone"  // both — default standalone
```

Mode is **never persisted** — always fetched live on panel open. `_wfbInitFetched` prevents
re-fetching on every subsequent panel open (one fetch per app session; manual refresh available).

#### Services control → systemctl

Both companion and relay expose service management. `services refresh --target companion` runs:
`systemctl list-units --type=service --all --no-pager` on the target and parses the output into
the live service list shown in CompanionControl / RelayControl.

Per-service actions: `sudo systemctl start|stop|restart|enable|disable <service-name>`.

**Known managed services (companion):**
`mavlink.router`, `microxrce-agent`, `rc_control_node`, `vision_streaming`, `tfmini`,
`ros2_px4_translation_node`, `ros2_external_node_reg`, `block-traffic`, `wifibroadcast@drone`, `ollama`

**Known managed services (relay):**
`wifibroadcast@gs`, `wifibroadcast-cluster@gs`, `mavlink.router`, `ssh-tunnel-to-companion`, `relay_files_sync.timer`

#### SSH terminal

Opens a new Windows CMD window with an SSH session to companion or relay:
```python
subprocess.Popen(["cmd.exe", "/c", "start", "", "cmd", "/k",
                  f"ssh -p {port} {user}@{ip}"])
```
The empty `""` is the window title (required syntax for `start`). Without it, `cmd` treats
the first quoted string as the window title and `ssh` is not found as a program.

#### Status check (connection chips)

`status` action: fast TCP socket test (5 s timeout), no SSH, no password:
```python
def is_reachable(ip, port, timeout=5):
    socket.create_connection((ip, int(port)), timeout=timeout).close()
    return True
```
Output: `COMPANION:reachable` / `COMPANION:unreachable` / `RELAY:reachable` / `RELAY:unreachable`
Parsed by FlyViewToolBar to colour the connection dots (green/red/grey).
Runs 3 s after app start, then every 30 s.

---

### 3.5 Signal Routing Pattern

`PXLABSRunner` is a singleton — signals fire on every `Connections` block simultaneously.
Each QML page uses a private boolean flag to claim its own responses:

```qml
property bool _myFetch: false

Connections {
    target: PXLABSRunner
    function onOutputReady(text) {
        if (!_myFetch) return    // not our command
        // process text...
    }
    function onCommandFinished(exitCode) {
        if (!_myFetch) return
        _myFetch = false
        _busy = false
    }
    function onCommandFailed(errorText) {
        if (!_myFetch) return
        _myFetch = false
        _busy = false
        statusText = "Error: " + errorText
    }
}

function _runMyCommand() {
    if (PXLABSRunner.running) return
    _myFetch = true
    _busy = true
    PXLABSRunner.run("companion something")
}
```

**Flags across the codebase:**

| File | Flag | Guards |
|------|------|--------|
| `FlyViewCustomLayer.qml` | `_wfbStatusFetch` | `relay wfb refresh` response |
| `FlyViewCustomLayer.qml` | `_panelCmdActive` | SSH terminal, power, WFB switch |
| `FlyViewToolBar.qml` | `_pxWifiFetch` | `companion wifi-temp` response |
| `FlyViewToolBar.qml` | `_statusFetch` | `status` reachability response |
| `CompanionControl.qml` | `_busy` | all CompanionControl commands |
| `RelayControl.qml` | `_busy` | all RelayControl commands |

---

### 3.6 FlyViewCustomLayer — System Control Panel

**File:** `src/FlightDisplay/FlyViewCustomLayer.qml`

Renders **below** the QGC toolbar (QGC's FlyViewCustomLayer z-order by design).
All toolbar additions go in `FlyViewToolBar.qml`, not here.

#### System Control Panel (right-edge slide-out)

`rightPanel` Rectangle docked to the right edge. Slides via `NumberAnimation` on `x`.

**Pull tab** — left edge of panel, always visible. Shows WFB mode glyph when panel closed:
- `◉` green = standalone active
- `⬡` blue = cluster active
- `⊙` grey = unknown / not fetched

**Resize handles** — 4 MouseAreas:

| Handle | Axis | z | preventStealing | Notes |
|--------|------|---|-----------------|-------|
| `leftResizeHandle` | Horizontal | 6 | true | Excludes header top |
| `bottomResizeHandle` | Vertical | 6 | true | Bottom edge |
| `topResizeHandle` | Vertical | 6 | false | Moves Y + resizes height; excludes tab width |
| `cornerResizeHandle` | Both | 6 | false | Bottom-right corner |

All at z:6 — above the `rpContent` Flickable which propagates mouse grab to z:5 level.
`preventStealing: true` on left + bottom handles prevents VerticalFlick Flickable from stealing
the drag event on the vertical axis.

**Top-edge resize math** (bottom of panel stays fixed):
```
newH = pressH - dy          // height shrinks/grows by delta
newY = pressY + dy          // top edge moves, bottom = pressY + pressH (constant)
```

**Geometry persistence:**

| Setting key | What it stores |
|-------------|----------------|
| `pxlabs_rp_y` | Panel vertical position |
| `pxlabs_rp_w` | Panel width (`_rpContentW`) |
| `pxlabs_rp_h` | Panel height |
| `pxlabs_cam_x` | Camera panel X |
| `pxlabs_cam_y` | Camera panel Y |

**WFB mode lifecycle:**
```
First panel open
  → panelOpenWatcher fires → Qt.callLater(_checkWfbMode)
      → PXLABSRunner.run("relay wfb refresh")
          → onOutputReady: parse SA/CA → _wfbMode updated
              → pull tab glyph + button highlight update reactively

Operator clicks Standalone / Cluster
  → PXLABSRunner.run("relay wfb switch --mode standalone|cluster")
      → onCommandFinished → start wfbCheckTimer (4 s)
          → wfbCheckTimer.triggered → _checkWfbMode() to confirm switch
```

---

### 3.7 FlyViewToolBar Additions

Three chips added left of PX4 brand logo:

```
[ Comp ● ]  [ Relay ● ]  [ Air-TX  23.4°C ↻ ]  [ PXLABS ]  [ PX4 logo ]
```

**Connection chips:** TCP reachability, auto every 30 s, manual refresh available.
`COMPANION:reachable/unreachable` + `RELAY:reachable/unreachable` from `status` action.

**Air-TX chip:** WFB RF card temperature from `companion wifi-temp`.
Green < 60°C / orange 60–74°C / red ≥ 75°C (matches `temp_overheat_warning = 60` in wifibroadcast.cfg).
Auto-poll timer controlled by settings. `onOutputReady` scans lines for a parseable float —
robust to stderr mixing into `_lastOutput`.

**PXLABS chip:** Static label, `qgcPal` colours, anchors Air-TX to its left.

---

### 3.8 Windows Installer

**Files:** `installer/G-Control-Setup.nsi`, `installer/EnvVarUpdate.nsh`
**Output:** `installer/G-Control-Setup-v<version>.exe` (~117 MB LZMA)

**What it installs:**
- `C:\Program Files\G-Control\G-Control.exe` + all Qt DLLs + GStreamer plugins
- `C:\Program Files\G-Control\tools\pxlabs_cli.exe` (no Python needed)
- `C:\Program Files\G-Control\config\ssh_config.json` (with `SetOverwrite off`)
- All QML dirs, platform plugins, translations

**Post-install:** Sets `GST_PLUGIN_PATH` in HKCU (user env, no reboot). Creates Start Menu + Desktop shortcuts. Registers in 64-bit Add/Remove Programs (`SetRegView 64` inside Section — required by NSIS 3.11+).

**Uninstall:** Removes all files. Deliberately keeps `config\` folder — user SSH credentials survive reinstall.

---

## 4. QML Rules (Learned the Hard Way)

### Underscore property signal naming
QML generates `_fooChanged` for `property _foo`. The handler `on_FooChanged` is unreliable.
Wrap in a non-underscore alias:
```qml
property bool _rightPanelOpen: false
property bool panelOpenWatcher: _rightPanelOpen  // no underscore — reliable
onPanelOpenWatcherChanged: { ... }
```

### Flickable event stealing
`Flickable` with `flickableDirection: VerticalFlick` steals mouse events from overlapping
`MouseArea` at the same or lower z. Fix: raise MouseArea to z:6 AND set `preventStealing: true`
on handles sharing an axis with the Flickable scroll direction.

### Qt Canvas 2D
`ctx.ellipse()` and `ctx.roundRect()` do **not** exist in Qt Canvas 2D.
Use `arc()`, `bezierCurveTo()`, `lineTo()`, `moveTo()` only.

### WFB mode — never persist
`_wfbMode` must start as `""` and always be fetched live.
Persisting via `saveGlobalSetting` causes stale green display after disconnect.

### QProcess output drain before commandFinished
Always drain `readAllStandardOutput()` + `readAllStandardError()` inside `_onFinished()`
and emit `outputReady` before emitting `commandFinished`. QProcess can buffer after `finished` fires.

### PyInstaller frozen path
Never use `__file__` to locate files next to the exe when frozen.
`__file__` → `%TEMP%\_MEI*\` (deleted after process exits). Use `sys.executable`.

---

## 5. Release History

| Version | Date | Tag | Branch | Highlights |
|---------|------|-----|--------|------------|
| v2.1.0 | 2026-03-20 | `PXLABS-v2.1.0` | `release/PXLABS-v2.1` | First stable release — all core features |
| v2.2.0 | 2026-03-22 | `PXLABS-v2.2.0` | `release/PXLABS-v2.2` | Resizable panel, WFB stale-green fix, camera-params, installer |
| v2.2.1 | 2026-06-04 | `PXLABS-v2.2.1` | `PXLABS-v2.1-integration` | Patch — CLI shutdown/reboot hang fix, ssh-terminal host key fix, ARCHITECTURE.md, NSIS 3.11 compat, FlyView panel abort-and-retry + status clear |
| v3.0.0 | 2026-06-14 | `PXLABS-v3.0.0` | `PXLABS-v2.1-integration` | Stable release — relay services panel fixed (per-target service lists + bash parsing fix), FlyView shutdown/reboot acknowledgement, camera resolution/FPS/format auto-populated dropdowns |

---

## 6. Session Log

### Session 1 — 2026-03-20 (Initial Integration)

**Goal:** Build the full PXLABS layer inside QGC.

**What was built:** PXLABSCommandRunner, all 4 settings pages, FlyViewCustomLayer,
FlyViewToolBar chips, pxlabs_cli.py with all subcommands, build/deploy/launch scripts.

**Bugs fixed:**

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| `IndentationError` in cli.py | Orphaned `if action == "front-switch":` after code reorder | Restored |
| UnicodeEncodeError on WFB ● | Windows cp1252 rejects U+25CF | `reconfigure(encoding="utf-8")` |
| SSH terminal not opening | `start cmd /k "ssh..."` — quoted string treated as window title | `start "" cmd /k ssh ...` |
| QProcess output buffered | `print()` default buffering under pipe | `flush=True` on all `print()` |
| Last output chunk lost | `commandFinished` before QProcess buffer drained | Drain both streams in `_onFinished()` first |
| Air-TX temp not reading | NIC detection guessed wrong interface | Read `/etc/default/wifibroadcast` first |

**Released:** v2.1.0

---

### Session 2 — 2026-03-21 (Bug Fixes + Features)

**Bugs fixed:**

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| WFB shows green after disconnect | `_wfbMode` loaded from `saveGlobalSetting` at startup | Remove persistence, start `""`, fetch on panel open |
| Random busy indicator | Shared `_busy` flag across pages via singleton broadcast | Per-page flags + `bgRetryTimer` |
| Service list broken | Timing issue in dynamic `_svcNames` population | Fixed population order |
| Panel wrong size | Layout restore order wrong | Fixed: width → height → y → clamp |
| WFB mode wrong | Parse logic incorrect | Match `SA:active/inactive` + `CA:active/inactive` lines explicitly |
| Single-axis resize broken | Handles at z:5 — Flickable propagates grab to z:5, stealing vertical drag | Raise to z:6, add `preventStealing: true` |

**Features added:**

| Feature | Implementation |
|---------|---------------|
| Top-edge resize | New `topResizeHandle`; `newH = pressH - dy`, `newY = pressY + dy` |
| camera-query full detail | `sudo vision_config_manager list-details <dev>` (was v4l2-ctl --list-formats-ext) |
| camera-params | CLI: `companion camera-params` → `vision_config_manager set-cam-params` |
| Remove Capture section | QGC has native capture; PXLABS section removed |
| Remove "Apply Camera" | Redundant with camera switch section |
| "Set Params" → "Apply" | Naming consistency |
| Companion icon | `camera.svg` → `servers.svg` |
| PXLABS toolbar chip | Static brand chip between Air-TX and PX4 logo |

**Released:** v2.2.0

---

### Session 3 — 2026-03-22 (Windows Installer)

**Goal:** Zero-dependency `G-Control-Setup.exe`.

**What was built:** `pxlabs_cli.spec`, `G-Control-Setup.nsi`, `EnvVarUpdate.nsh`.

**Bugs fixed:**

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| `python: can't open pxlabs_cli.py` | Runner called `python .py`; .py not in install dir | Default → `.exe`; detect `.exe` → run directly |
| All SSH broken (pycparser) | `optimize=2` strips docstrings; PLY uses them as grammar rules | `optimize=0` |
| SSH timeout — wrong IP | Frozen `__file__` → temp dir → empty config → wrong IP | `sys.frozen` check: use `sys.executable` |
| Two Add/Remove Programs entries | NSIS writes to 32-bit `WOW6432Node` by default | `SetRegView 64` inside Section (NSIS 3.11: no longer valid at global scope) |

---

## 7. Build & Deploy Reference

```bat
# Full rebuild from CMD (not bash — pause blocks)
build_pxlabs.bat

# Full rebuild from bash / Claude Code
cmd //c "E:\\qgc-pxlabs\\do_build.bat"

# Rebuild pxlabs_cli.exe only
cd E:\qgc-pxlabs\tools
python -m PyInstaller pxlabs_cli.spec --distpath E:\qgc-pxlabs\build_clean\Release\tools --workpath E:\qgc-pxlabs\build_pyinstaller_work --noconfirm

# Test CLI before packaging (must show real config path, no pycparser warnings)
E:\qgc-pxlabs\build_clean\Release\tools\pxlabs_cli.exe config show

# Rebuild installer (bump APP_VERSION in .nsi for new releases)
cd E:\qgc-pxlabs\installer
"C:\Program Files (x86)\NSIS\makensis.exe" G-Control-Setup.nsi

# Dev launch
E:\qgc-pxlabs\Launch-GControl.bat
```

---

### Session 4 — 2026-06-04 (Architecture Docs + CLI Bug Fixes)

**Goals:**
1. Create full system architecture documentation
2. Verify relay station config against live repo
3. Fix companion shutdown/reboot and ssh-terminal failures

---

#### 4.1 ARCHITECTURE.md — New File

Created `ARCHITECTURE.md` with:

- **Mermaid diagram** — renders natively on GitHub; shows all 3 nodes (PC, Vind-Rly, Vind-Roz) with network interfaces, services, and all connections
- **Data flow breakdowns** — MAVLink path, H.264 video downlink, SSH tunnel path, relay management SSH
- **WFB-NG parameters table** — channel, region, txpower, MCS, bandwidth, STBC, LDPC, temp threshold
- **WFB-NG stream table** — stream IDs (0x00/0x10/0x90/0xa0/0x20), FEC ratios, directions
- **Software stack tables** — G-Control.exe layers, companion services, relay services
- **Network address table** — all nodes, interfaces, IPs, purposes
- **Encryption section** — drone.key / gs.key symmetric keypair

`README.md` docs table updated to link ARCHITECTURE.md as first entry.

---

#### 4.2 Relay Architecture Corrections

Initial diagram was written from memory. Verified against live `ArvinVeiyon/Relay_Station_Pxlabs` repo. Six corrections applied:

| Item | Was Wrong | Corrected To |
|------|-----------|--------------|
| P2P interface name | `wlan0` | `p2p-wlan0-0` |
| eth0 / CPE610 IPs | `eth0 → CPE610 10.5.7.102` (ambiguous) | relay eth0 = `10.5.7.100`, CPE610 = `10.5.7.102` (separate rows) |
| WFB service name | `wifibroadcast@gs` | `wifibroadcast-cluster@gs` (instance-based, cluster-capable) |
| SSH tunnel mechanism | "SSH forward" | `autossh` explicitly — uses `autossh -M 0 -L 0.0.0.0:2222:10.5.5.87:22 roz@10.5.5.87` |
| Missing service | — | `mediamtx.service` — low-latency RTSP streaming server |
| Missing service | — | `dhcpd` — serves P2P network 10.5.6.0/24, pool .50–.99, GW 10.5.6.1 |

---

#### 4.3 CLI Bug Fixes — pxlabs_cli.py

**Bug 1: companion/relay shutdown and reboot reported as error**

Root cause: `sudo shutdown now` / `sudo reboot` kill the SSH connection before paramiko's
`recv_exit_status()` can complete. Paramiko raises an exception → `ssh_exec` returns
`(False, "", "SSH error: ...", 1)` → G-Control shows failure even though the command ran.

Diagnosis: confirmed on live hardware — paramiko returned SSH error while companion
successfully executed the command.

Fix: replaced direct `shutdown`/`reboot` with `systemd-run --on-active=0`:

```python
# Before
ssh_exec(..., "sudo shutdown now")
ssh_exec(..., "sudo reboot")

# After
ssh_exec(..., "sudo systemd-run --on-active=0 systemctl poweroff")
ssh_exec(..., "sudo systemd-run --on-active=0 systemctl reboot")
```

`systemd-run` creates a transient timer unit detached from the SSH session.
The SSH command returns exit 0 immediately; systemd fires the poweroff/reboot
independently. Verified on both companion and relay before implementing.

Applied to: `companion_actions()` (lines ~329–336) and `relay_actions()` (lines ~368–371).

---

**Bug 2: companion ssh-terminal window opens but SSH connection fails**

Root cause: Port `:2222` on the relay presents the **companion's SSH host key**, not the
relay's key. This is a different key from `relay:22`. The Windows SSH client either
prompts for unknown host (may be swallowed silently) or rejects with a host key mismatch
if the companion was ever reinstalled.

Diagnosis: confirmed with `ssh-keyscan`:
```
10.5.6.101:22   → relay ed25519 key:  ...H0gfS7Anyzx1JOzhGxUQg...
[10.5.6.101]:2222 → companion ed25519: ...K/6/50edQwZT6wctHVTqAWO...
```
Keys are different. Relay `ssh-terminal` works because relay:22 key is already trusted.

Fix: added `-o StrictHostKeyChecking=no` to the companion `ssh-terminal` Popen command:

```python
# Before
f'start cmd /k ssh -p {port} {username}@{ip}'

# After
f'start cmd /k ssh -o StrictHostKeyChecking=no -p {port} {username}@{ip}'
```

Acceptable on a private drone LAN — the companion is a known trusted device.
Applied to both Windows (`cmd.exe Popen`) and Linux (`gnome-terminal`) paths.

---

**pxlabs_cli.exe rebuilt** after fixes via PyInstaller spec (no new warnings).

---

**Bug 3: NSIS 3.11 — `SetRegView 64` not valid at global scope**

Discovered during v2.2.1 installer build. NSIS 3.11 tightened scope rules — `SetRegView`
is now only valid inside a `Section` or `Function`. Previously worked at global scope in
earlier NSIS 3.x versions.

Error:
```
Error: command SetRegView not valid outside Section or Function (line 22)
```

Fix: removed `SetRegView 64` from global scope, added it as the first line inside both
`Section "G-Control (required)"` (install) and `Section "Uninstall"` — so all registry
writes in both directions use the 64-bit hive correctly.

---

**Bug 4: FlyView SSH terminal button requires 3–4 presses**

Root cause: `_runPanelCmd` in `FlyViewCustomLayer.qml` silently returns when
`PXLABSRunner.running` is true — no feedback, no retry. The toolbar background polls
(`companion wifi-temp`, `status`) run on the same singleton runner and take 3–5 s. During
that window every button press is silently dropped.

Diagnosis: `CompanionControl.qml` (Settings page) already has the fix — it checks the
`pxlabs_bg_active` flag, aborts the background poll, and retries the user command via a
400 ms `bgRetryTimer`. `FlyViewCustomLayer._runPanelCmd` had none of this.

Fix: mirrored the abort-and-retry pattern into `_runPanelCmd`:

```qml
// Before
function _runPanelCmd(args, statusMsg) {
    if (PXLABSRunner.running) return   // silent drop
    ...
}

// After
function _runPanelCmd(args, statusMsg) {
    if (PXLABSRunner.running) {
        if (QGroundControl.loadGlobalSetting("pxlabs_bg_active", "0") === "1") {
            _panelRetryArgs   = args
            _panelRetryStatus = statusMsg
            _panelStatus      = "Waiting…"
            PXLABSRunner.abort()
            _panelRetryTimer.start()   // 400 ms, then re-runs command
        } else {
            _panelStatus = "⚠ Busy — retry in a moment"
        }
        return
    }
    ...
}
```

Added `_panelRetryTimer` (400 ms, same as CompanionControl `bgRetryTimer`) and two new
properties: `_panelRetryArgs`, `_panelRetryStatus`.

---

**Bug 5: Status area shows "Opening SSH terminal…" indefinitely after terminal opens**

Root cause: `onCommandFinished` only updated `_panelStatus` on failure. On success
(exit 0), `_panelStatus` retained the last `outputReady` text — for ssh-terminal that
was "Opening SSH terminal: ssh -p 2222 roz@10.5.6.101" — which stayed visible forever.

Fix: on `commandFinished(exitCode === 0)`:
- If command was `ssh-terminal` → set `_panelStatus = "✓ Terminal opened"`
- Start `_panelStatusClearTimer` (2.5 s) to blank the status for all successful commands

```qml
if (exitCode !== 0) {
    _panelStatus = "✗ Failed (exit " + exitCode + ")"
} else {
    if (_root._lastPanelCmd.indexOf("ssh-terminal") >= 0)
        _panelStatus = "✓ Terminal opened"
    _panelStatusClearTimer.restart()   // clears after 2.5 s
}
```

`_lastPanelCmd` property added to track which command is currently running.

---

### Session 5 — 2026-06-14 (Relay Services, Shutdown Ack, Camera Dropdowns)

**Goals:**
1. Fix relay services panel showing every service as "unknown" (Bug B / Bug D)
2. Fix System Control panel shutdown/reboot buttons giving no acknowledgement (Bug A — power actions)
3. Replace manual camera resolution/FPS/format copy-paste with auto-populated dropdowns

---

#### 5.1 Relay Services Panel — Wrong Service List + Bash Parsing Bug (Bug B, Bug D)

**File:** `tools/pxlabs_cli.py` — `services_actions()`

Root cause was two-fold:

1. `services_actions()` used a single hardcoded `important_services` list (companion services
   only) regardless of `--target`. For `--target relay`, `systemctl is-active` was queried
   against service names that don't exist on the relay → "unknown" for everything.
2. The refresh command used the `$(cmd || echo unknown)` pattern. `systemctl is-active` /
   `is-enabled` print a status word (e.g. `failed`, `inactive`) AND exit non-zero — so the
   `||` fallback still ran, appending a spurious extra `unknown` line per service and
   desyncing the parsed output from the service list.

Fix: added two module-level lists, `COMPANION_SERVICES` and `RELAY_SERVICES`; `services_actions()`
now picks `default_services = RELAY_SERVICES if target == "relay" else COMPANION_SERVICES`.
Rewrote the refresh command to avoid `||`:

```bash
a=$(systemctl is-active "$s" 2>/dev/null); a=${a:-unknown}
e=$(systemctl is-enabled "$s" 2>/dev/null); e=${e:-unknown}
echo "$s|$a|$e"
```

`RELAY_SERVICES` includes `mediamtx.service` (closes Bug D), plus `isc-dhcp-server.service`,
`isc-dhcp-server6.service`, `ssh-tunnel-to-companion.service`, `wfb-cluster.service`,
`wifibroadcast.service`, `wifibroadcast@gs.service`, `relay_files_sync.timer`, and the
shared system services — verified against the live relay's actual unit list.

**Verified live:** `services refresh --target relay` (10.5.6.101:22) → 20 clean lines
(e.g. `isc-dhcp-server6.service|failed|enabled`); `--target companion` → 19 clean lines.
Both correct, no spurious lines.

---

#### 5.2 FlyView Shutdown/Reboot Acknowledgement (Bug A — power actions)

**File:** `src/FlightDisplay/FlyViewCustomLayer.qml`

**Symptom:** Pressing Companion/Relay Shutdown or Restart in the System Control panel gave
no feedback — user couldn't tell if the command was received, and kept pressing the button
until the device actually shut down.

Root cause: `_confirm(title, msg, cmd)` called `PXLABSRunner.run(cmd)` directly from the
Yes-dialog callback, bypassing `_runPanelCmd` entirely — no busy state, no `_panelStatus`
text, no abort-and-retry against background polls.

Fix: `_confirm` now takes a 4th `statusMsg` argument and routes through `_runPanelCmd`:

```qml
function _confirm(title, msg, cmd, statusMsg) {
    mainWindow.showMessageDialog(title, msg, Dialog.Yes | Dialog.No,
                                 function() { _runPanelCmd(cmd, statusMsg) })
}
```

All 4 call sites (Companion/Relay Restart/Shutdown) updated with status messages
(`"Restarting companion…"`, `"Shutting down companion…"`, etc.). Extended the
`onCommandFinished` success branch so exit-0 sets `_panelStatus` to
`"✓ Shutdown command sent"` / `"✓ Reboot command sent"` / `"✓ Terminal opened"`
depending on `_lastPanelCmd`, then restarts `_panelStatusClearTimer`.

**Verified live by user on hardware — "worked perfectly".**

**Remaining scope (Bug A not fully closed):** the camera switch quick-buttons in the
FlyView panel (`PXLABSRunner.run("companion front-switch")` etc., ~lines 810/818/830/838)
still call the runner directly and have the same silent-drop gap. See updated Bug A note
in §9.

---

#### 5.3 Camera Resolution/FPS/Format Dropdowns

**File:** `src/UI/AppSettings/CompanionControl.qml`

Previously the "Camera Device (Advanced)" section had free-text Resolution/FPS fields and
a hardcoded MJPG/UYVY Format dropdown — the user had to run "Query Details", read the
`vision_config_manager list-details` output, and manually copy the pixel size/fps/format
into the fields before pressing Apply.

Added `_parseCameraQuery(text)`, which parses the `list-details` output into:

- a map of `{ format: { order: [resolutions...], fps: { resolution: [fps...] } } }` from
  the "Supported Formats" section (`[N]: 'FORMAT'`, `Size: Discrete WxH`,
  `Interval: Discrete ... (X fps)`)
- the camera's currently-active format/resolution/fps (`Pixel Format`, `Width/Height`,
  `Frames per second` lines)

`_applyCameraQuery(text)` uses this to populate three cascading `QGCComboBox`es
(Format → Resolution → FPS, each computed via `readonly property var` so changing the
format updates the resolution list, and changing the resolution updates the fps list),
pre-selecting the camera's current values. `Qt.callLater()` sequences the index updates
across the dependent comboboxes after each model change.

"Query Details" sets `_camQueryActive = true`; `onCommandFinished` calls
`_applyCameraQuery(_camLastOutput)` on success. "Apply" sends
`companion camera-params --device <dev> --resolution <res> --fps <fps> --format <fmt>`.
Works for any device selected in the Device dropdown (`/dev/video0`, `/dev/video2`,
`/dev/video3`) — re-querying repopulates the dropdowns for that device.

Removed the old free-text Resolution/FPS `QGCTextField`s.

---

**Released:** v3.0.0

---

## 9. Known Issues / Pending Improvements

Identified at end of Session 4 (2026-06-04). Bugs B and D resolved, Bug A partially
resolved, in Session 5 (2026-06-14) — see status notes below. Bug C remains open.
Priority: High → Low.

---

### Bug A (High) — FlyView `_confirm` and camera buttons bypass abort-and-retry

**Status: PARTIALLY RESOLVED (Session 5, 2026-06-14).** The System Control panel's
Companion/Relay Restart/Shutdown buttons now route through `_confirm` → `_runPanelCmd`
and give proper `_panelStatus` feedback ("✓ Shutdown command sent" etc.) — this was the
user-reported issue (shutdown gave no acknowledgement) and is verified fixed on live
hardware. The camera switch quick-buttons below (~810/818/830/838) still call
`PXLABSRunner.run(args)` directly and remain unfixed — see remaining scope below.

**File:** `src/FlightDisplay/FlyViewCustomLayer.qml`

**Lines affected (remaining):** ~810, ~818, ~830, ~838 (camera switch buttons —
front-switch, bottom-switch, split-front-bottom, split-bottom-front)

**Symptom:** Clicking a camera switch button while a background poll is running silently drops the command — no feedback, no retry.

**Root cause:** These buttons call `PXLABSRunner.run(args)` directly without going through `_runPanelCmd`. The abort-and-retry logic only covers `_runPanelCmd`. Direct callers bypass it entirely.

**Fix needed:** Route the remaining `PXLABSRunner.run(args)` calls (camera switch buttons) through `_runPanelCmd(args, statusMsg)`.

---

### Bug B (High) — Relay services panel shows all "unknown" status

**Status: RESOLVED (Session 5, 2026-06-14).** `services_actions()` now selects
`COMPANION_SERVICES` or `RELAY_SERVICES` based on `--target`, and the refresh command no
longer uses the `$(cmd || echo unknown)` pattern that produced spurious extra lines.
Verified live: `--target relay` → 20 clean lines, `--target companion` → 19 clean lines.
See §6 Session 5.1.

**File:** `tools/pxlabs_cli.py` — `services_actions()` function

**Symptom:** Opening the Relay Station settings page → Services tab shows every service as "unknown" or missing.

**Root cause:** `services_actions()` uses a single hardcoded service list (`wifibroadcast@drone`, `mavlink.router`, `microxrce-agent`, `vision_streaming`, etc.) regardless of whether `--target companion` or `--target relay` is passed. The relay does not run companion services, so `systemctl is-active` returns "unknown" for all of them.

---

### Bug C (Medium) — No SSH tunnel health visibility

**Symptom:** The Connection Status chips in the toolbar check TCP reachability on `relay:2222`. A successful TCP connection only proves the relay is reachable and port 2222 is open — it does not confirm that the autossh reverse tunnel to the companion is alive. If the WFB link between relay and companion drops, relay:22 is still reachable but relay:2222 returns ECONNREFUSED. The chip currently shows no distinction between these states.

**Fix needed options:**
1. Add a third chip or change chip colour/icon when TCP to `:2222` fails while TCP to `:22` succeeds (indicates tunnel down, relay up).
2. Or: query `systemctl is-active ssh-tunnel-to-companion.service` on the relay and surface the result as a tunnel-health glyph.

---

### Bug D (Low) — `mediamtx` not in relay services panel

**Status: RESOLVED (Session 5, 2026-06-14).** `mediamtx.service` is now included in
`RELAY_SERVICES` (added as part of Bug B's fix). See §6 Session 5.1.

**Symptom:** `mediamtx` runs on the relay (RTSP re-streamer for camera feeds) and is documented in ARCHITECTURE.md, but it does not appear in the relay services panel in G-Control.
