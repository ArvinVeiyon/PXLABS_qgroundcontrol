# G-Control — Development Document

Full architecture, design decisions, and development history for the PXLABS fork of QGroundControl.
For a raw file-by-file change log see `PXLABS_CHANGES.md`.

---

## 1. What G-Control Is

**G-Control** is a customised build of QGroundControl v5.0.8 for the **Vind-Roz** drone system.

QGC covers standard GCS functions (MAVLink telemetry, mission planning, parameter tuning, video).
G-Control adds a second layer on top: **remote management of the companion computer and relay station**
over SSH, entirely from within the GCS window. The operator never needs a separate terminal.

Everything added is strictly **additive** — no native QGC file is deleted or restructured.
All PXLABS-added code is in new files or clearly marked additive blocks in the two native files that
were touched (`QGCApplication.cc` to register the singleton, `FlyViewToolBar.qml` for toolbar chips).

| | |
|---|---|
| Base | QGroundControl v5.0.8 (tag `qgc-v5.0.8-base`) |
| Dev branch | `PXLABS-v2.1-integration` |
| GitHub | `https://github.com/ArvinVeiyon/PXLABS_qgroundcontrol` |
| Build output | `E:\qgc-pxlabs\build_clean\Release\G-Control.exe` |
| Installer | `installer\G-Control-Setup-v<version>.exe` |
| Companion SSH | `roz@10.5.6.101:2222` (via relay tunnel) |
| Relay SSH | `vind-admin@10.5.6.101:22` |

---

## 2. System Architecture

### 2.1 High-Level Components

```
┌─────────────────────────────────────────────────────────────────┐
│                        G-Control.exe (Windows)                  │
│                                                                  │
│  ┌──────────────────────┐   ┌────────────────────────────────┐  │
│  │  QGC Native Layer    │   │  PXLABS Layer (additive)       │  │
│  │  (MAVLink/PX4/video) │   │                                │  │
│  │                      │   │  QML UI          C++ Bridge    │  │
│  │  FlyView             │   │  ─────────       ───────────   │  │
│  │  Toolbar             │   │  FlyViewCustomLayer.qml        │  │
│  │  Settings            │   │  FlyViewToolBar.qml (chips)    │  │
│  │  Parameters          │   │  CompanionControl.qml          │  │
│  │  Mission             │   │  RelayControl.qml          ┌───┤  │
│  │                      │   │  ConnectionControl.qml     │   │  │
│  │                      │   │  PXLABSSettings.qml        │   │  │
│  └──────────────────────┘   └────────────────────────────┼───┘  │
│                                                           │      │
│                              PXLABSCommandRunner.cc ◄────┘      │
│                              (QProcess → pxlabs_cli.exe)         │
└──────────────────────────────────────┬──────────────────────────┘
                                       │ subprocess
                              ┌────────▼────────┐
                              │ pxlabs_cli.exe  │
                              │ (PyInstaller)   │
                              │  paramiko SSH   │
                              └────┬───────┬────┘
                                   │       │
                     SSH :2222     │       │  SSH :22
                    ┌──────────────▼─┐   ┌─▼──────────────┐
                    │  Vind-Roz      │   │  Vind-Rly       │
                    │  (Companion)   │   │  (Relay)        │
                    │  RPi5 Ubuntu   │   │  RPi5 Ubuntu    │
                    │  PX4 + ROS2    │   │  WFB-NG gateway │
                    └────────────────┘   └─────────────────┘
```

### 2.2 The Three Layers in Detail

**Layer 1 — QGC Native (unchanged)**
Standard QGroundControl: MAVLink link to PX4 via relay's mavlink.router, telemetry, HUD,
video feed (GStreamer H264 from companion's vision_streaming service), mission planning, parameters.

**Layer 2 — PXLABS QML + C++ (G-Control additions)**
All UI for companion/relay management. Runs inside the same Qt process as QGC.
Communicates downward through `PXLABSRunner` (the C++ singleton) to spawn CLI subprocess.

**Layer 3 — pxlabs_cli (subprocess)**
Python-based SSH bridge compiled into a standalone exe. Completely decoupled from the Qt process.
Opens a fresh paramiko SSH connection per command, executes remote commands, streams stdout/stderr
back through QProcess pipes, exits. Stateless — no persistent connection held.

---

## 3. Component Deep-Dive

### 3.1 PXLABSCommandRunner (C++ Singleton)

**Files:** `src/Utilities/PXLABSCommandRunner.h/.cc`
**QML URI:** `QGroundControl.PXLABS` → object name `PXLABSRunner`
**Registration:** `src/QGCApplication.cc` — `qmlRegisterSingletonType<PXLABSCommandRunner>(...)`

This is the only C++ code added by PXLABS. It is a thin QProcess wrapper with three jobs:

1. **Locate and launch the CLI** — reads `cliPath` and `pythonPath` from `QSettings`.
   - If `cliPath` ends with `.exe`: runs it directly — installed mode, no Python needed.
   - If `cliPath` ends with `.py`: prepends `pythonPath` — developer mode with source script.
   - Default `cliPath` = `<appDir>/tools/pxlabs_cli.exe`.

2. **Stream output to QML** — `readyReadStandardOutput` + `readyReadStandardError` both accumulate
   into `_lastOutput` and emit `outputReady(text)`. Stderr is included in the same stream
   (intentional — CLI mixes status messages into stderr for QProcess visibility).

3. **Signal completion** — `_onFinished` drains any remaining buffered bytes first (critical: QProcess
   buffers can flush after `finished` fires), then emits `commandFinished(exitCode)`.
   `_onError` (FailedToStart etc.) emits `commandFailed(errorText)`.

**Key design constraint:** Only one command runs at a time (`_running` guard). QML must check
`PXLABSRunner.running` before calling `run()` — attempting to run while busy returns a
`commandFailed` signal immediately.

**Signal broadcast:** `outputReady` and `commandFinished` are broadcast to **all** QML pages that
have a `Connections { target: PXLABSRunner }` block. Each page must use a boolean flag to determine
whether the signal belongs to it (see §3.3).

**QML API:**
```qml
import QGroundControl.PXLABS

// Run a command — args only, runner prepends cli path
PXLABSRunner.run("companion front-switch")
PXLABSRunner.run("relay wfb refresh")
PXLABSRunner.run("services refresh --target companion")

// Abort (kills subprocess)
PXLABSRunner.abort()

// Properties
PXLABSRunner.running        // bool — true while subprocess is alive
PXLABSRunner.lastOutput     // QString — cumulative stdout+stderr so far

// Signals
onOutputReady(text)         // fires on each chunk of output
onCommandFinished(exitCode) // fired after drain — 0 = success
onCommandFailed(errorText)  // process failed to start, crashed, etc.
```

---

### 3.2 pxlabs_cli (SSH Bridge)

**File:** `tools/pxlabs_cli.py` → compiled to `build_clean\Release\tools\pxlabs_cli.exe`

A stateless CLI program. G-Control spawns it as a subprocess per command. It connects to the
companion or relay over SSH, executes one remote command, prints output, and exits.

#### Config resolution

```python
# Installed (frozen exe): use sys.executable to find real install dir
if getattr(sys, "frozen", False):
    ROOT = Path(sys.executable).resolve().parents[1]
else:
    ROOT = Path(__file__).resolve().parents[1]

CONFIG_PATH = ROOT / "config" / "ssh_config.json"
```

Config file: `<install>\config\ssh_config.json` (JSON, not encrypted).
Passwords are NOT in the JSON — they live in the Windows keyring under service name `"Drone-Control"`,
account = SSH username. This means passwords survive reinstall and are not exposed in plain text.

#### Connection selection (companion)

```python
def pick_companion_host(cfg):
    # Try primary (relay tunnel 10.5.6.101:2222) first
    if is_reachable(primary_ip, primary_port):
        return primary_ip, primary_port
    # Fall back to secondary (direct WFB IP 10.5.5.87:22)
    if secondary_ip and is_reachable(secondary_ip, secondary_port):
        return secondary_ip, secondary_port
    # Return primary anyway — SSH will give a proper error
    return primary_ip, primary_port
```

Primary path goes through the relay's SSH tunnel (P2P network). Secondary is direct WFB if the
operator is on-site. Reachability is a fast TCP socket test (5 s timeout), not a full SSH handshake.

#### sudo password feeding

```python
def _sudo_wrap(command, password):
    # Feed password via printf, not echo — echo exposes the password in `ps aux` on the remote
    if command.startswith("sudo "):
        pw = password.replace("'", "'\"'\"'")
        return f"printf '%s\\n' '{pw}' | sudo -S {command[5:]}"
    return command
```

All remote commands that need root use `sudo -S` (read password from stdin). The password is piped
from `printf` to avoid it appearing in the remote process list.

#### SSH session lifecycle

One `paramiko.SSHClient` is opened per `ssh_exec()` call, used, and closed in `finally`.
No persistent connection — simpler, and avoids keepalive complexity for the GCS use case
(commands are infrequent, typically operator-triggered).

#### Output format contract

CLI stdout is free text displayed directly in the QML `TextArea`.
Two structured formats are used:
- **Status check:** `COMPANION:reachable` / `COMPANION:unreachable` / `RELAY:reachable` / `RELAY:unreachable` — parsed by FlyViewToolBar connection chips.
- **WFB mode:** `SA:active` / `SA:inactive` / `CA:active` / `CA:inactive` — parsed by FlyViewCustomLayer WFB mode logic.

All other output (camera query, service list, etc.) is displayed as raw text in the relevant QML page.

#### Command surface

| Subcommand | Target | What it does |
|------------|--------|-------------|
| `companion front-switch` | Companion | `sudo vision_config_manager /dev/video0` |
| `companion bottom-switch` | Companion | `sudo vision_config_manager /dev/video2` |
| `companion split-front-bottom` | Companion | `sudo vision_config_manager /dev/video0 /dev/video2` |
| `companion split-bottom-front` | Companion | `sudo vision_config_manager /dev/video2 /dev/video0` |
| `companion camera-query --device` | Companion | `sudo vision_config_manager list-details <dev>` |
| `companion camera-params --device --resolution --fps --format` | Companion | `sudo vision_config_manager set-cam-params <dev> <res> <fps> --format <fmt>` |
| `companion wifi-temp` | Companion | Read WFB NIC temp — `/etc/default/wifibroadcast` → wfb-cli → procfs → sysfs |
| `companion reboot` | Companion | `sudo reboot` |
| `companion shutdown` | Companion | `sudo shutdown -h now` |
| `companion ssh-terminal` | Companion | Opens `cmd.exe /c start "" cmd /k ssh -p <port> <user>@<ip>` |
| `relay wfb refresh` | Relay | `wfb-rlyctl status` — outputs SA/CA lines |
| `relay wfb switch --mode` | Relay | `wfb-rlyctl switch <mode>` |
| `relay wfb list-nics` | Relay | `wfb-rlyctl list-nics` |
| `relay wfb set-nics --nics` | Relay | `wfb-rlyctl set-nics <nic>` |
| `relay wfb logs` | Relay | `journalctl -u wifibroadcast@gs -n 60 --no-pager` |
| `relay wfb view-config` | Relay | `cat /etc/wifibroadcast.cfg` |
| `relay reboot` | Relay | `sudo reboot` |
| `relay shutdown` | Relay | `sudo shutdown -h now` |
| `relay ssh-terminal` | Relay | Opens CMD window with SSH session |
| `services refresh --target` | Either | Lists systemd services + status |
| `services start\|stop\|restart\|enable\|disable --target --service` | Either | `systemctl <action> <service>` |
| `status` | Both | Fast TCP reachability check, no SSH, no password |
| `config show` | Local | Print resolved JSON config + path |
| `config set [--flags]` | Local | Update `ssh_config.json` + keyring passwords |

---

### 3.3 Signal Routing Pattern (Multi-Page Isolation)

`PXLABSRunner` is a singleton — its signals fire on every `Connections` block across every loaded
QML page simultaneously. Without isolation, page A's `_busy` flag would be cleared by page B's command.

**Pattern used throughout:**

```qml
// Page-local flag — set true before run(), cleared in onCommandFinished/onCommandFailed
property bool _myFetch: false

Connections {
    target: PXLABSRunner

    function onOutputReady(text) {
        if (!_myFetch) return      // not our command — ignore
        // process text...
    }
    function onCommandFinished(exitCode) {
        if (!_myFetch) return
        _myFetch = false
        _busy = false
        // update UI...
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

**Flags in use across the codebase:**

| File | Flag | Guards |
|------|------|--------|
| `FlyViewCustomLayer.qml` | `_wfbStatusFetch` | `relay wfb refresh` response |
| `FlyViewCustomLayer.qml` | `_panelCmdActive` | SSH terminal, power, WFB switch |
| `FlyViewToolBar.qml` | `_pxWifiFetch` | `companion wifi-temp` response |
| `FlyViewToolBar.qml` | `_statusFetch` | `status` reachability response |
| `CompanionControl.qml` | `_busy` | all CompanionControl commands |
| `RelayControl.qml` | `_busy` | all RelayControl commands |

---

### 3.4 FlyViewCustomLayer — System Control Panel

**File:** `src/FlightDisplay/FlyViewCustomLayer.qml`

This is the main in-flight UI addition. It renders **below** the QGC toolbar (FlyViewCustomLayer
z-order is below toolbar by QGC design) so all added toolbar elements live in `FlyViewToolBar.qml`.

#### System Control Panel (right-edge)

A `Rectangle` (`id: rightPanel`) docked to the right edge of the FlyView. Slides open/closed
with a `NumberAnimation` on its `x` property (slides off-screen right when closed).

**Pull tab** — a narrow strip on the left edge of `rightPanel`. Always visible. Shows WFB mode
glyph (◉ standalone / ⬡ cluster / ⊙ unknown) when panel is closed so the operator can see WFB
status at a glance without opening the panel.

**Resize handles** — 4 `MouseArea` items around the panel edges:

| Handle | Axis | Anchors | z | Notes |
|--------|------|---------|---|-------|
| `leftResizeHandle` | Horizontal | left edge, between header and bottom | 6 | `preventStealing: true` |
| `bottomResizeHandle` | Vertical | bottom edge | 6 | `preventStealing: true` |
| `topResizeHandle` | Vertical | top edge (excludes tab width) | 6 | moves panel Y + resizes height |
| `cornerResizeHandle` | Both | bottom-right corner | 6 | standard both-axis drag |

All at z:6 to beat the `rpContent` Flickable which propagates mouse grab to z:5 level.
`preventStealing: true` on left and bottom handles prevents the vertical Flickable from stealing
the drag on the vertical axis.

**Top-edge resize math** (bottom of panel stays fixed):
```
newH = pressH - dy      // shrink/grow by delta
newY = pressY + dy      // move top edge, bottom = pressY + pressH (constant)
```

**Panel geometry persistence** — saved to `QGroundControl.saveGlobalSetting`:
- `pxlabs_rp_y` — vertical position
- `pxlabs_rp_w` — width (stored as `_rpContentW`)
- `pxlabs_rp_h` — height

Restored in `Component.onCompleted` → `_restoreRpLayout()`.

**Content** — a `Flickable` (`id: rpContent`) containing:
- WFB Mode section: Standalone / Cluster buttons + ↻ Refresh + active mode badge
- Companion section: Restart / Shutdown (with confirm dialog) + SSH Terminal
- Relay section: Restart / Shutdown (with confirm dialog) + SSH Terminal

**WFB mode lifecycle:**
```
Panel opens first time
  └─ panelOpenWatcher fires → Qt.callLater(_checkWfbMode)
       └─ PXLABSRunner.run("relay wfb refresh")
            └─ onOutputReady: parse SA:/CA: lines → set _wfbMode
                 └─ pull tab glyph + button highlight update reactively

Operator clicks Standalone/Cluster button
  └─ PXLABSRunner.run("relay wfb switch --mode standalone|cluster")
       └─ onCommandFinished: start wfbCheckTimer (4 s)
            └─ wfbCheckTimer.triggered: _checkWfbMode() again to confirm
```

Mode is **never persisted** to `saveGlobalSetting` — always fetched live to prevent stale display
after reconnect. `_wfbInitFetched` ensures the fetch only happens once per app session
(subsequent panel opens do not re-fetch unless manually refreshed).

#### Camera Switch Panel

A separate draggable `Rectangle` (`id: cameraPanel`). Drag handle = header bar only (prevents
accidental drag on button clicks). Position clamped to screen bounds.

Buttons: Front / Bottom / Split Front→Bottom / Split Bottom→Front. Each calls:
```qml
PXLABSRunner.run("companion front-switch")   // etc.
```

Position saved to `pxlabs_cam_x` / `pxlabs_cam_y` on drag end.

---

### 3.5 FlyViewToolBar Additions

**File:** `src/QmlControls/FlyViewToolBar.qml` (modified — additive only)

Three chips added to the right side of the toolbar, left of the PX4 brand logo:

```
[ Comp ● ]  [ Relay ● ]  [ Air-TX  23.4°C ↻ ]  [ PXLABS ]  [ PX4 logo ]
```

#### Connection Status Chips (Comp● / Relay●)

- Dot colour: green = reachable, red = unreachable, grey = unknown/checking
- Auto-check: 3 s after `Component.onCompleted`, then every 30 s via `Timer`
- Manual refresh: click ↻ on the Air-TX chip (same action)
- Command: `PXLABSRunner.run("status")` — fast TCP socket check, no SSH, no password required
- Output parsed: `COMPANION:reachable` / `RELAY:reachable` etc.
- Flag: `_statusFetch` — set true before run, cleared in `onCommandFinished`

#### Air-TX Temperature Chip

- Shows WFB RF card (rtl88x2eu) temperature from companion
- Colour: green < 60°C, orange 60–74°C, red ≥ 75°C, blue = N/A or error
- Auto-poll: controlled by `pxlabs_wifi_temp_enabled` (bool setting) and
  `pxlabs_wifi_temp_interval` (seconds, minimum 10)
- Manual refresh: click chip
- Command: `PXLABSRunner.run("companion wifi-temp")`
- Output: `onOutputReady` scans lines for a parseable float — robust to mixed stderr

**Temperature detection on companion (3-step fallback):**
1. Read `/etc/default/wifibroadcast` to get actual WFB NIC name (e.g. `wlx00c0cab6db3b`)
2. Try `wfb-cli drone` output — parse `XX°C` or `XX C` pattern
3. Fall back to procfs (`/sys/class/net/<nic>/...`) or sysfs thermal scan

#### PXLABS Brand Chip

- Static label "PXLABS", uses `qgcPal` colors
- Anchored left of PX4 logo; Air-TX anchors to `pxLabsChip.left`

---

### 3.6 Settings Pages

All loaded via `PXLABSPagesModel.qml` which is included as a separate `ListModel` section in the
app settings sidebar — no modification to QGC's `SettingsPagesModel.qml` list (entries are injected).

#### ConnectionControl.qml
- SSH credentials: companion IP, port, username, password (written to keyring + config JSON)
- Relay SSH credentials: relay IP, port, username, password
- Periodic connection check: enable/disable + interval
- Air-TX temperature polling: enable/disable + interval
- Apply buttons write config file and keyring immediately

#### PXLABSSettings.qml
- Python executable path (dev mode — path to `python.exe`)
- CLI path (path to `pxlabs_cli.py` or `pxlabs_cli.exe`)
- "Test CLI" button — runs `config show`, displays raw output
- Both paths written to `QSettings` via `PXLABSRunner.setCliPath()` / `setPythonPath()`

#### CompanionControl.qml
- **Camera Switch** — Front / Bottom / Split F→B / Split B→F
- **Camera Device (Advanced)**:
  - Device selector (combo: `/dev/video0`, `/dev/video2`, `/dev/video3`)
  - Query button → `companion camera-query --device` → shows full `vision_config_manager list-details` output
  - Resolution, FPS, Format inputs + Apply → `companion camera-params --device --resolution --fps --format`
- **System** — Reboot / Shutdown (with confirmation dialogs)
- **Services** — live list from `services refresh --target companion`; per-service Start/Stop/Restart/Enable/Disable

#### RelayControl.qml
- **WFB Mode** — Standalone / Cluster buttons + refresh
- **NIC Config** — list NICs, set active NIC
- **System** — Reboot / Shutdown
- **Services** — same pattern as CompanionControl

---

### 3.7 Windows Installer

**Files:** `installer/G-Control-Setup.nsi`, `installer/EnvVarUpdate.nsh`
**Output:** `installer/G-Control-Setup-v<version>.exe`

#### Build pipeline

```
G-Control.exe  (CMake/MSVC build)
     +
pxlabs_cli.exe (PyInstaller onefile from tools/pxlabs_cli.py)
     +
Qt DLLs + GStreamer DLLs + QML dirs  (windeployqt + deploy_dlls.bat)
     │
     └─► makensis G-Control-Setup.nsi
              └─► G-Control-Setup-v2.2.0.exe  (~117 MB LZMA)
```

#### What the installer does

1. Copies all files to `C:\Program Files\G-Control\`
2. Sets `GST_PLUGIN_PATH=%INSTDIR%\gstreamer-plugins` in HKCU (user env, no reboot)
3. Creates Start Menu shortcut + Desktop shortcut
4. Registers uninstaller in Add/Remove Programs (`SetRegView 64` — 64-bit hive)
5. `config\ssh_config.json` installed with `SetOverwrite off` — user config survives reinstall

#### What uninstall does

Removes all installed files and registry entries.
**Deliberately keeps `config\` folder** — SSH credentials (passwords are in Windows keyring, IP/port
in the JSON) are preserved across uninstall/reinstall cycles.

#### PyInstaller notes

- `optimize=0` — PLY (used by pycparser, used by cffi, used by cryptography, used by paramiko)
  stores grammar production rules in function `__doc__` strings. `optimize=2` strips all docstrings,
  breaking the parser table entirely and silently failing all SSH operations.
- `sys.frozen` path fix — `__file__` in a onefile frozen exe resolves to the temp `_MEI*` extraction
  directory (deleted after process exits). Must use `sys.executable` to locate files next to the exe.

---

## 4. QML Technical Rules (G-Control Specific)

These are constraints discovered during development that apply to all future QML work in this project.

### Underscore property signal naming
QML generates `_fooChanged` signal for `property _foo`. The handler `on_FooChanged` is unreliable.
**Fix:** Wrap in a non-underscore alias:
```qml
property bool _rightPanelOpen: false
property bool panelOpenWatcher: _rightPanelOpen   // no underscore
onPanelOpenWatcherChanged: { /* reliable */ }
```

### Flickable event stealing
A `Flickable` with `flickableDirection: Flickable.VerticalFlick` will steal mouse press events
from overlapping `MouseArea` items at the same or lower z-level.
**Fix:** Set `MouseArea.z` to 6 (above Flickable's effective grab level of 5) AND
`preventStealing: true` on handles that share an axis with the Flickable scroll direction.

### Qt Canvas 2D (QML)
`ctx.ellipse()` and `ctx.roundRect()` do **not** exist in Qt's Canvas 2D implementation.
Use `arc()`, `bezierCurveTo()`, `lineTo()`, and `moveTo()` only.

### WFB mode — never persist
`_wfbMode` must start as `""` and be fetched live. Persisting via `saveGlobalSetting` causes
stale green display after disconnect (the saved value survives app restart).

### QProcess output drain before commandFinished
QProcess can buffer stdout/stderr after the `finished` signal fires. Always drain
`readAllStandardOutput()` + `readAllStandardError()` inside `_onFinished()` and emit
`outputReady` before emitting `commandFinished`. Otherwise QML clears the fetch flag
and ignores the last chunk of output.

---

## 5. Release History

| Version | Date | Tag | Branch | Highlights |
|---------|------|-----|--------|------------|
| v2.1.0 | 2026-03-20 | `PXLABS-v2.1.0` | `release/PXLABS-v2.1` | First stable release — all core features working |
| v2.2.0 | 2026-03-22 | `PXLABS-v2.2.0` | `release/PXLABS-v2.2` | Resizable panel (all 4 edges), WFB stale-green fix, camera-params, Windows installer |

---

## 6. Session Log

### Session 1 — 2026-03-20 (Initial Integration)

**Goal:** Build the full PXLABS layer inside QGC from scratch.

**What was built:**
- `PXLABSCommandRunner.h/.cc` — C++ singleton, QProcess wrapper, registered to QML
- `ConnectionControl.qml`, `PXLABSSettings.qml`, `CompanionControl.qml`, `RelayControl.qml` — all settings pages
- `FlyViewCustomLayer.qml` — System Control panel + camera switch panel
- `FlyViewToolBar.qml` additions — Air-TX chip, connection status chips
- `tools/pxlabs_cli.py` — full SSH bridge with all subcommands
- Build/deploy/launch scripts

**Bugs fixed during integration:**

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| `IndentationError` in cli.py | Orphaned `if action == "front-switch":` line after code reorder | Restored indentation |
| UnicodeEncodeError on WFB ● | Windows cp1252 console codec rejects U+25CF | `stdout.reconfigure(encoding="utf-8", errors="replace")` at startup |
| SSH terminal window title issue | `start cmd /k "ssh..."` treats quoted string as window title → ssh not found | Removed inner quotes: `start "" cmd /k ssh ...` |
| QProcess output buffering | `print()` buffered under pipe mode | Added `flush=True` to all `print()` calls in `run_cmd()` |
| Last output chunk lost | `commandFinished` emitted before QProcess buffer fully drained | Drain `readAllStandardOutput/Error()` in `_onFinished()` before emitting `commandFinished` |
| Air-TX temp not reading | NIC detection using wrong method | Read `/etc/default/wifibroadcast` first for actual WFB NIC, fall back to procfs |

**Released:** v2.1.0

---

### Session 2 — 2026-03-21 (Bug Fixes + Features)

**Bugs fixed:**

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| WFB mode shows green after disconnect | `_wfbMode` loaded from `saveGlobalSetting` on startup | Remove persistence, start as `""`, fetch once on panel open |
| Periodic busy indicator | Multiple commands sharing `_busy` flag across pages via singleton broadcast | Per-page boolean flags + `bgRetryTimer` |
| Service list not rendering / duplicating | Timing issue in dynamic `_svcNames` list population | Fixed population sequence |
| Panel wrong size on startup | Layout restore order wrong | Fixed: restore width → height → y → clamp |
| WFB mode sync wrong | Parse logic incorrect | Rewrote: match `SA:active/inactive` + `CA:active/inactive` lines explicitly |
| Single-axis resize not working | `leftResizeHandle` + `bottomResizeHandle` at z:5 — Flickable inside `rpContent` (z:0) propagates grab to z:5, stealing vertical drag | Raise all handles to z:6, add `preventStealing: true` |

**Features added:**

| Feature | Details |
|---------|---------|
| Top-edge resize handle | New `topResizeHandle`; math: `newH = pressH - dy`, `newY = pressY + dy` (bottom fixed) |
| camera-query full detail | Changed from `v4l2-ctl --list-formats-ext` to `sudo vision_config_manager list-details <dev>` |
| camera-params action | New CLI: `companion camera-params --device --resolution --fps --format` → `vision_config_manager set-cam-params` |
| Remove Capture section | QGC has native capture; removed redundant PXLABS Capture section from CompanionControl |
| Remove "Apply Camera" button | Camera switch already covered by top section; removed from Advanced |
| "Set Params" → "Apply" | Rename to match established naming convention |
| Companion page icon | `camera.svg` → `servers.svg` (companion is an air-unit server, not a camera) |
| PXLABS brand chip in toolbar | Static label between Air-TX chip and PX4 logo |

**Released:** v2.2.0

---

### Session 3 — 2026-03-22 (Windows Installer)

**Goal:** Ship a zero-dependency `G-Control-Setup.exe`.

**What was built:**
- `tools/pxlabs_cli.spec` — PyInstaller spec for standalone CLI exe
- `installer/G-Control-Setup.nsi` — NSIS installer script
- `installer/EnvVarUpdate.nsh` — NSIS env var helper (bundled locally)

**Bugs fixed:**

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| `python: can't open pxlabs_cli.py` after install | Runner called `python pxlabs_cli.py` — .py not present in install dir; default path was `.py` | Default → `.exe`; runner detects `.exe` extension and runs directly |
| pycparser warnings + all SSH broken | `optimize=2` in spec strips docstrings; PLY uses docstrings as grammar rules for cffi/cryptography/paramiko | `optimize=2` → `optimize=0` |
| SSH timeout — wrong IP | Frozen `__file__` points to `%TEMP%\_MEI*\` extraction dir; config read from empty temp location | `sys.frozen` check: use `sys.executable` for path resolution when frozen |
| Two Add/Remove Programs entries | NSIS default writes to 32-bit `WOW6432Node` hive even for 64-bit install | Added `SetRegView 64` to NSIS script |

---

## 7. Build & Deploy Reference

```bat
# Full rebuild (CMD — not bash, pause blocks bash)
build_pxlabs.bat

# Full rebuild (bash / Claude Code — no pause)
cmd //c "E:\\qgc-pxlabs\\do_build.bat"

# Rebuild CLI exe only
cd E:\qgc-pxlabs\tools
python -m PyInstaller pxlabs_cli.spec --distpath E:\qgc-pxlabs\build_clean\Release\tools --workpath E:\qgc-pxlabs\build_pyinstaller_work --noconfirm

# Test CLI before packaging
E:\qgc-pxlabs\build_clean\Release\tools\pxlabs_cli.exe --help
E:\qgc-pxlabs\build_clean\Release\tools\pxlabs_cli.exe config show
# Verify: no pycparser warnings, config path = build_clean\Release\config\ssh_config.json

# Rebuild installer (bump APP_VERSION in .nsi first for new releases)
cd E:\qgc-pxlabs\installer
"C:\Program Files (x86)\NSIS\makensis.exe" G-Control-Setup.nsi

# Dev launch
E:\qgc-pxlabs\Launch-GControl.bat
```
