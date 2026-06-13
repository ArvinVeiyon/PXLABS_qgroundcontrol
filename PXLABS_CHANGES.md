# PXLABS Integration — Native QGC Change Log

**Rule: ADDITIONS ONLY. No removal of any existing QGC code ever.**

All PXLABS additions are marked with `// PXLABS integration — additive` comments.

---

## Release History

| Version | Tag | Branch | Date | Status |
|---------|-----|--------|------|--------|
| v3.0.0 | `PXLABS-v3.0.0` | `release/PXLABS-v3.0` | 2026-06-14 | ✅ Latest — relay services panel fix (per-target lists + bash parsing fix), FlyView shutdown/reboot acknowledgement, camera resolution/FPS/format dropdowns |
| v2.2.1 | `PXLABS-v2.2.1` | `PXLABS-integration` | 2026-06-04 | Previous stable — CLI shutdown/ssh-terminal fixes, NSIS 3.11 compat, FlyView panel responsiveness |
| v2.2.0 | `PXLABS-v2.2.0` | `release/PXLABS-v2.2` | 2026-03-22 | Previous stable |
| v2.1.0 | `PXLABS-v2.1.0` | `release/PXLABS-v2.1` | 2026-03-20 | Previous stable |

### Installer (v3.0.0 — latest)

`G-Control-Setup-v3.0.0.exe` at `installer\G-Control-Setup-v3.0.0.exe` (~117 MB, LZMA compressed).
Previous: `G-Control-Setup-v2.2.1.exe` (tag `PXLABS-v2.2.1`), `G-Control-Setup-v2.2.0.exe` (tag `PXLABS-v2.2.0`).

- Installs to `C:\Program Files\G-Control\`
- Bundles `pxlabs_cli.exe` — no Python required on target machine
- Sets `GST_PLUGIN_PATH` in user environment automatically
- Creates Start Menu + Desktop shortcuts
- Registers in Add/Remove Programs (64-bit registry)
- Config (`config\ssh_config.json`) not overwritten on reinstall — SSH credentials preserved
- Uninstall keeps `config\` folder

**Development branch:** `PXLABS-integration`
**GitHub:** `https://github.com/ArvinVeiyon/PXLABS_qgroundcontrol`

---

## Native Files Touched (Additions Only)

### 1. `src/QGCApplication.cc`
- **Line added (~72):** `#include "PXLABSCommandRunner.h"`
- **Lines added (~310):** `qmlRegisterSingletonType<PXLABSCommandRunner>(...)` — registers `PXLABSRunner` singleton to QML URI `QGroundControl.PXLABS`

### 2. `src/Utilities/CMakeLists.txt`
- **Lines added:** `PXLABSCommandRunner.cc` and `PXLABSCommandRunner.h` added to `target_sources`

### 3. `src/UI/AppSettings/CMakeLists.txt`
- **Lines added:** `ConnectionControl.qml`, `PXLABSSettings.qml`, `CompanionControl.qml`, `RelayControl.qml` added to `QML_FILES`

### 4. `src/GPS/GPSProvider.cc`
- **Lines added (~222):** `GPSDriverUBX::Settings _ubxSettings{}` + `_ubxSettings.mode = UBXMode::Normal` added before existing constructor call. Constructor updated to pass `_ubxSettings` as 6th arg — required because `PX4-GPSDrivers main` branch changed the API. Original 5-arg call preserved as comment. Build cannot compile without this.

### 5. `src/UI/AppSettings/SettingsPagesModel.qml`
- **Lines added:** 4 `ListElement` entries — Connection, PXLABS Settings, Companion, Relay Station — inserted before Mock Link

### 6. `src/FlightDisplay/FlyViewCustomLayer.qml` *(REPLACED — was empty stub)*
- Right-edge expandable **System Control** panel (‹/› tab, slides with animation)
  - Companion: Restart / Shutdown buttons (with confirmation dialog)
  - Relay: Restart / Shutdown buttons (with confirmation dialog)
  - SSH Terminal buttons for Companion and Relay (opens new CMD window via `start "" cmd /k ssh ...`)
  - **WFB Mode section**: Standalone (green) + Cluster (blue) buttons; active mode highlighted; calls `relay wfb switch --mode` then 4s timer then `relay wfb refresh` to verify
- **Left-edge "Transmission Mode" panel** (‹/› tab on left, purple accent):
  - Dish antenna drawn with Qt Canvas 2D safe methods only (`bezierCurveTo`, `arc`, `lineTo`, `createLinearGradient`) — NO `ellipse()`/`roundRect()` (not in Qt Canvas)
  - Active mode badge: "◉ STANDALONE — Active" / "⬡ CLUSTER — Active" / "⊙ No Mode Set"
  - Standalone (green) + Cluster (blue) mode buttons with `● ACTIVE` indicator
  - On open: `Qt.callLater(_checkWfbMode)` to sync status from relay
  - `wfbCheckTimer` (4s, non-repeating) waits after mode switch before re-checking
- **WFB mode detection**: `relay wfb refresh` → parse `SA:active/inactive` + `CA:active/inactive` lines
  - `SA:active` + `CA:inactive` → "standalone"
  - `CA:active` + `SA:inactive` → "cluster"
  - Both active → defaults to "standalone"
- **WiFi temp chip REMOVED from this file** — moved to `FlyViewToolBar.qml` (see §7 below)
- Draggable camera switch panel: Front / Bottom / Split F→B / Split B→F
- Panel position saved/restored via `QGroundControl.saveGlobalSetting/loadGlobalSetting`

### 7. `src/QmlControls/FlyViewToolBar.qml` *(MODIFIED — additive)*
- Added `import QGroundControl.PXLABS`
- WiFi temp chip (`pxWifiChip` Rectangle, z:20) placed directly in toolbar, anchored to `brandImage.left` (or `parent.right` if logo hidden):
  - Shows "WiFi X.X°C" color-coded: green (<60°C), orange (60–74°C), red (≥75°C), blue (N/A/—/…)
  - "↻" refresh icon (shows "…" during fetch); clicking chip triggers manual refresh
  - `pxlabs_wifi_temp_enabled` setting gates auto-poll Timer
  - `pxlabs_wifi_temp_interval` setting (seconds) controls Timer interval (min 10s)
  - `_pxWifiFetch` flag gates PXLABSRunner Connections so toolbar only consumes `wifi-temp` responses
  - `Component.onCompleted: { _pxLoadSettings(); Qt.callLater(_pxFetchWifi) }` — loads settings and fetches on startup

---

## New Files Added (All PXLABS, zero QGC native)

| File | Purpose |
|------|---------|
| `src/Utilities/PXLABSCommandRunner.h` | C++ QObject — QProcess wrapper, exposes `PXLABSRunner` singleton to QML |
| `src/Utilities/PXLABSCommandRunner.cc` | Implementation — runs `pxlabs_cli.exe <args>` (installed) or `python pxlabs_cli.py <args>` (dev); auto-detected by `.exe` extension |
| `src/UI/AppSettings/ConnectionControl.qml` | **Settings page — SSH config for companion + relay. CONFIGURE FIRST before using CLI. Also: Periodic Connection Check settings + Wi-Fi Temperature Polling settings.** |
| `src/UI/AppSettings/PXLABSSettings.qml` | Settings page — Python path, CLI path, Test CLI |
| `src/UI/AppSettings/CompanionControl.qml` | Settings page — Camera switch, Camera Device (Advanced: query/set params), System, Services. Capture removed (QGC has native capture). |
| `src/UI/AppSettings/RelayControl.qml` | Settings page — WFB mode, NICs, System, Services |
| `tools/pxlabs_cli.py` | CLI bridge — SSH to companion/relay |
| `tools/pxlabs_cli.spec` | PyInstaller spec — bundles cli.py → pxlabs_cli.exe (optimize=0, sys.frozen path fix) |
| `installer/G-Control-Setup.nsi` | NSIS installer script — packages full Release\ into setup exe |
| `installer/EnvVarUpdate.nsh` | NSIS helper — sets/removes GST_PLUGIN_PATH in user environment |
| `build_pxlabs.bat` | Build script — VS2022 + Qt 6.8.3, Z: subst for space-free path |
| `do_build.bat` | No-pause build wrapper usable from bash/Claude Code |
| `deploy_dlls.bat` | **Run after EVERY build** — copies GStreamer DLLs + Qt DLLs + pxlabs_cli.py to build_clean/Release |
| `Launch-GControl.bat` | **Always use to launch** — sets GST_PLUGIN_PATH, GST_REGISTRY_REUSE_PLUGIN_SCANNER=no |
| `Launch-GControl-Debug.bat` | Debug launch — writes GStreamer log to Release\gst_debug.log |
| `PXLABS_CHANGES.md` | This file — tracks all native QGC changes |

---

## Launch Order (IMPORTANT)

1. Build: run `build_pxlabs.bat` from CMD (requires MSVC environment — do NOT run from bash)
2. Deploy: run `deploy_dlls.bat` — **MUST do this after every build**, copies DLLs + pxlabs_cli.py
3. Launch: use `Launch-GControl.bat` — sets required GStreamer env vars
4. First run: go to Settings → Connection, enter SSH credentials, click Apply Companion + Apply Relay

---

## QML Import Pattern

All PXLABS QML pages import:
```qml
import QGroundControl.PXLABS
```
Then call: `PXLABSRunner.run("companion front-switch")` etc.

**C++ auto-detects:** if `cliPath` ends with `.exe`, runs it directly; otherwise prepends `python <cli_path>` (dev workflow). QML passes args only.

Signals available on `PXLABSRunner`:
- `outputReady(text)` — stdout lines as they arrive
- `commandFinished(exitCode)` — process exited
- `commandFailed(errorText)` — process failed to start

---

## CLI Command Reference

```
# Companion camera switch
python pxlabs_cli.py companion front-switch
python pxlabs_cli.py companion bottom-switch
python pxlabs_cli.py companion split-front-bottom
python pxlabs_cli.py companion split-bottom-front

# Companion camera device (advanced)
python pxlabs_cli.py companion camera-apply --device /dev/video0
python pxlabs_cli.py companion camera-query --device /dev/video0              # full detail via vision_config_manager list-details
python pxlabs_cli.py companion camera-params --device /dev/video0 --resolution 1920x1080 --fps 60 --format MJPG

# Companion system
python pxlabs_cli.py companion reboot
python pxlabs_cli.py companion shutdown
python pxlabs_cli.py companion ssh-terminal

# Companion misc
python pxlabs_cli.py companion wifi-temp

# Relay WFB
python pxlabs_cli.py relay wfb refresh
python pxlabs_cli.py relay wfb switch --mode standalone|cluster
python pxlabs_cli.py relay wfb status
python pxlabs_cli.py relay wfb logs
python pxlabs_cli.py relay wfb view-config
python pxlabs_cli.py relay wfb list-nics
python pxlabs_cli.py relay wfb set-nics --nics <nic>

# Relay system
python pxlabs_cli.py relay reboot
python pxlabs_cli.py relay shutdown
python pxlabs_cli.py relay ssh-terminal

# Services
python pxlabs_cli.py services refresh --target companion|relay
python pxlabs_cli.py services start|stop|restart|enable|disable --target companion|relay --service <name>

# Config
python pxlabs_cli.py config show
python pxlabs_cli.py config set \
    --primary-ip 10.5.6.101 --primary-port 2222 \
    --secondary-ip <ip> --secondary-port 22 \
    --username roz --companion-password <pass> \
    --relay-ip 10.5.6.101 --relay-ssh-port 22 \
    --relay-username vind-admin --relay-password <pass>
```

---

## GStreamer Notes

- GStreamer 1.22.12 at `E:\gstreamer\1.0\msvc_x86_64`
- No `gstlibav.dll` — H264 decoded via `gstd3d11.dll` (d3d11h264dec)
- `deploy_dlls.bat` creates `build_clean\lib\gstreamer-1.0` — required by GStreamer.cc for internal path resolution
- `Launch-GControl.bat` sets `GST_PLUGIN_PATH` + `GST_REGISTRY_REUSE_PLUGIN_SCANNER=no`
- For debug: use `Launch-GControl-Debug.bat` — writes `Release\gst_debug.log`

---

## Session Changes (2026-03-22 — Installer)

### installer/G-Control-Setup.nsi + EnvVarUpdate.nsh (NEW)
- NSIS installer script packaging full `build_clean\Release\` into `G-Control-Setup-v2.2.0.exe`
- Installs to `C:\Program Files\G-Control\`, sets `GST_PLUGIN_PATH` (HKCU), creates shortcuts, registers uninstaller
- `SetRegView 64` — writes to 64-bit registry hive (not WOW6432Node); placed inside Sections (required by NSIS 3.11+)
- `SetOverwrite off` for `config\ssh_config.json` — user settings survive reinstall
- `EnvVarUpdate.nsh` bundled locally (not relying on NSIS system Include dir)

### tools/pxlabs_cli.spec
- `optimize=2` → `optimize=0` — PLY/pycparser uses function docstrings as grammar rules; stripping them breaks cffi → cryptography → paramiko → all SSH commands fail

### tools/pxlabs_cli.py
- Added `sys.frozen` check for config path resolution:
  ```python
  if getattr(sys, "frozen", False):
      ROOT = Path(sys.executable).resolve().parents[1]   # real install dir
  else:
      ROOT = Path(__file__).resolve().parents[1]          # dev: relative to .py
  ```
  Without this, frozen exe uses `__file__` which points to `%TEMP%\_MEI*\` extraction dir → config read from empty temp location → wrong IP → SSH timeout on every command.

### src/Utilities/PXLABSCommandRunner.cc
- Default `cliPath` changed from `tools/pxlabs_cli.py` → `tools/pxlabs_cli.exe`
- `run()` now detects `.exe` extension and runs cli directly (no python prepend):
  ```cpp
  if (cli.endsWith(".exe", Qt::CaseInsensitive)) {
      _process->setProgram(cli);
      _process->setArguments(extraArgs);
  } else {
      // dev workflow: python pxlabs_cli.py <args>
      _process->setProgram(pythonPath());
      _process->setArguments(QStringList{cli} + extraArgs);
  }
  ```

---

## Session Changes (2026-03-20 evening)

### pxlabs_cli.py
- Fixed `IndentationError`: missing `if action == "front-switch":` line was orphaned after ssh-terminal reorder
- Added `sys.stdout.reconfigure(encoding="utf-8", errors="replace")` at top — fixes UnicodeEncodeError when WFB status output contains `●` (U+25CF) under Windows cp1252
- SSH terminal: changed to `start cmd /k ssh -p {port} {user}@{ip}` (no quotes around ssh command) — quoted form `start cmd /k "ssh..."` caused cmd to treat entire quoted string as program filename
- `run_cmd`: added `flush=True` to both `print` calls — prevents output buffering under QProcess pipe mode
- `wifi-temp`: added wfb-cli drone fallback (step B) between procfs and sysfs, matching old app's 3-step logic

### PXLABSCommandRunner.cc
- `_onFinished`: now drains remaining `readAllStandardOutput()` + `readAllStandardError()` and emits `outputReady` BEFORE emitting `commandFinished` — fixes race where buffered output arrived after QML already cleared the fetch flag

### FlyViewCustomLayer.qml
- **Left "Transmission Mode" panel completely removed** (dish Canvas, mode buttons, pull tab)
- `_leftPanelOpen` and `_lpWidth` properties removed
- Right "System Control" panel now contains all WFB controls: Standalone + Cluster buttons, ↻ Refresh button inline with "WFB Mode" label, active mode badge
- WFB auto-check on panel open removed — was firing SSH call to relay every open

---

## Session Changes (2026-03-20 — v2.1 Release)

### Air-TX Temp chip — renamed + fully working
- Renamed "WiFi Temp" → **"Air-TX Temp"** (measures WFB RF card / rtl88x2eu temperature)
- **Root cause of non-working temp fixed**: rewrote `wifi-temp` in `pxlabs_cli.py` to match standalone app logic exactly:
  - Interface detection now reads `/etc/default/wifibroadcast` for real WFB NIC name first, falls back to procfs scan
  - Step B (wfb-cli) now uses proper `XX°C / XX C` regex — was grabbing any number
  - Each step uses its own `exec_command` on a persistent SSH connection — more reliable than single large shell script
- `ssh_exec` now catches all connection exceptions and returns clean error instead of crashing Python with unhandled exception
- `onOutputReady` in FlyViewToolBar now scans lines for a parseable float — robust to stderr mixed into `_lastOutput`

### Connection Status chips added to toolbar
- New **`Comp ●`** and **`Relay ●`** chips in FlyViewToolBar, left of Air-TX chip
- Green = reachable, Red = unreachable, Grey = unknown
- Auto-check 3s after startup, then every 30s; click ↻ to refresh manually
- New `pxlabs_cli.py status` command — fast TCP socket check, no password needed, outputs `COMPANION:reachable/unreachable` + `RELAY:reachable/unreachable`
- Chip colors use `qgcPal` palette to match QGC dark theme (no more custom blue)

### System Control panel — layout improvements
- Panel top margin pushed down below QGC camera controls (was overlapping)
- Pull tab moved to top of panel (was vertically centered)
- Pull tab now shows **WFB mode glyph** (◉ green = standalone / ⬡ blue = cluster / ⊙ grey = unknown) when panel is closed
- Button heights reduced (`2.5→2.1`, `2.2→1.85`) + spacing tightened — WFB Mode section now visible without scrolling

---

---

## v2.2 — Session Changes (2026-03-22)

### FlyViewCustomLayer.qml — System Control panel: resizable + WFB mode fix

**Resizable panel (all edges):**
- Panel changed from fixed/anchored to **draggable + resizable**
- Left-edge resize handle — drag to change panel width
- Bottom-edge resize handle — drag to change panel height (bottom moves, top fixed)
- Top-edge resize handle — drag to change panel height (top moves, bottom fixed)
- Bottom-left corner handle — resize both axes simultaneously
- All handles: `z:6` + `preventStealing:true` — prevents Flickable inside panel from stealing mouse grab (was the root cause of single-axis handles not working)
- Panel size + Y position saved/restored via `saveGlobalSetting`

**WFB mode stale-green fix:**
- `_wfbMode` no longer loaded from persisted settings on startup — always starts as `""` (grey ⊙)
- `saveGlobalSetting("pxlabs_wfb_mode")` removed — no persistence
- WFB mode fetched **once** automatically when panel is first opened (`panelOpenWatcher` property)
- Subsequent checks: only via ↻ Refresh button or after a mode switch (4s timer)
- No more stale green when relay is disconnected

**Panel busy tracking:**
- `_panelCmdActive` replaces `PXLABSRunner.running` for status indicator — tracks own panel commands only, not global runner state

---

### FlyViewToolBar.qml — UI polish + PXLABS brand chip

- Added **PXLABS brand chip** between Air-TX chip and PX4 logo
- Air-TX chip now anchors to `pxLabsChip.left` instead of `brandImage.left`
- Air-TX font size: `smallFontPointSize` → `defaultFontPointSize` (more legible)
- Temperature label format improved: `"Air-TX  val °C"` (proper spacing)
- Connection status widget height/width/spacing tweaked for better fit

---

### CompanionControl.qml — Busy isolation, service list, camera cleanup

- `_busy` now tracks **own commands only** — not affected by background connection polls
- Added `bgRetryTimer` (400ms) — if background fetch is running when user clicks a button, it aborts the fetch and retries the user command automatically
- Dynamic **service list** — `_svcNames` populated at runtime via ↻ Refresh instead of hardcoded
- **Capture section removed** — QGC has native image capture; `Capture Front` / `Capture Bottom` buttons gone
- **Camera Device (Advanced)** — removed redundant "Apply Camera" button (covered by Camera Switch buttons above)
- Renamed "Set Params" → **"Apply"** to match v1.4 drone control app naming
- Added **Resolution / FPS / Format** inputs with Apply button → calls `camera-params`

---

### PXLABSPagesModel.qml

- Companion settings page icon changed from `camera.svg` → **`servers.svg`** (companion is an air unit computer, not a camera)

---

### pxlabs_cli.py — camera-query + new camera-params action

- `camera-query`: now calls `sudo vision_config_manager list-details {device}` — returns **full detail** (v4l2-ctl `--all`, udevadm info, supported formats). Was previously calling `v4l2-ctl --list-formats-ext` (formats only).
- Added **`camera-params`** action: `vision_config_manager set-cam-params {device} {resolution} {fps} --format {fmt}`
  - New CLI args: `--resolution` (default `1920x1080`), `--fps` (default `60`), `--format` (default `MJPG`)
  - Matches v1.4 standalone app "Apply" behaviour in Camera Settings tab

---

## Known Issues / Next Session TODO

*(none — all previously known issues resolved)*

---

## Session Changes (2026-03-20)

### ConnectionControl.qml — Added two new settings sections
- **Periodic Connection Check**: enable toggle, interval (sec), timeout (sec), max attempts — saves to `pxlabs_conn_check_*` global settings
- **Wi-Fi Temperature Polling**: enable toggle, poll interval (sec) — saves `pxlabs_wifi_temp_enabled` + `pxlabs_wifi_temp_interval`

### FlyViewToolBar.qml — WiFi temp chip moved here from FlyViewCustomLayer
- Root cause: FlyViewCustomLayer renders BELOW the QGC toolbar layer — chip at toolbar-height Y was hidden behind it
- Fix: injected chip directly into FlyViewToolBar.qml at z:20, anchored to `brandImage.left`
- Chip reads `pxlabs_wifi_temp_enabled` / `pxlabs_wifi_temp_interval` on startup

### FlyViewCustomLayer.qml — System Control + Transmission Mode panels
- Renamed panel to "System Control" (was "System Power")
- Added SSH Terminal buttons (companion + relay) to System Control panel
- Added WFB Standalone/Cluster buttons to System Control panel (right side)
- Added left-side "Transmission Mode" panel with dish antenna and mode buttons
- WFB mode detection changed from `relay wfb status` → `relay wfb refresh` + SA/CA parsing
- Canvas crash fix: removed `ctx.ellipse()` / `ctx.roundRect()` (not in Qt Canvas API) — rewrote with `bezierCurveTo` + `arc`
- Property signal fix: wrapper `property string modeWatch: _root._wfbMode` avoids underscore signal naming issue
- Post-switch delay: `wfbCheckTimer` (4s) replaces `Qt.callLater(Qt.callLater(...))` for reliable confirmation

### pxlabs_cli.py — SSH terminal + wifi-temp fixes
- `ssh-terminal` (companion + relay): moved BEFORE `get_password()` call — was blocked by missing-password early return
- `ssh-terminal` Popen fix: `start "" cmd /k ssh -p {port} {username}@{ip}` — empty `""` = window title, `cmd` = program name (avoids `'"ssh..."' is not recognized` error)
- Added `print(f"Opening SSH terminal: ssh -p {port} {username}@{ip}", flush=True)` before Popen
- `wifi-temp`: moved before password check; returns `"N/A"` immediately if no password stored (avoids crash)

---

---

## v2.2.1 Patch — 2026-06-04

### ARCHITECTURE.md (NEW)

Full system architecture reference committed to repo root:
- Mermaid network diagram (renders on GitHub) — PC, Vind-Rly, Vind-Roz nodes
- Data flow breakdowns: MAVLink, H.264 video, SSH tunnel, relay management
- WFB-NG stream table (stream IDs, FEC, directions)
- Software stack tables, network address table, encryption notes
- README docs table updated to include link

### pxlabs_cli.py — Two bug fixes

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| `companion/relay shutdown` + `reboot` always reported error in G-Control | `recv_exit_status()` blocks; `shutdown now` kills SSH connection before paramiko can read exit status | Replace with `sudo systemd-run --on-active=0 systemctl poweroff/reboot` — detached from SSH session, returns exit 0 immediately |
| `companion ssh-terminal` fails silently | Port `:2222` presents companion host key (different from relay:22 key); not in Windows known_hosts | Add `-o StrictHostKeyChecking=no` to SSH command — verified correct via `ssh-keyscan` on live hardware |

### installer/G-Control-Setup.nsi — NSIS 3.11 compatibility fix

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| `Error: command SetRegView not valid outside Section or Function` | NSIS 3.11 no longer allows `SetRegView` at global scope | Moved `SetRegView 64` into both `Section "G-Control"` and `Section "Uninstall"` |

### FlyViewCustomLayer.qml — FlyView panel responsiveness fixes

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| SSH terminal button requires 3–4 presses in FlyView panel | `_runPanelCmd` silently dropped button press when runner was busy with background polls (wifi-temp/status) — no abort, no retry, no feedback | Mirrored `CompanionControl` abort-and-retry: detect `pxlabs_bg_active`, abort poll, retry via `_panelRetryTimer` (400 ms) |
| Status area shows "Opening SSH terminal…" forever after terminal opens | `onCommandFinished` only updated `_panelStatus` on failure — success left last CLI output text permanently | On success: set "✓ Terminal opened" for ssh-terminal; auto-clear all success status after 2.5 s via `_panelStatusClearTimer` |

---

## v3.0.0 — 2026-06-14

### pxlabs_cli.py — services_actions() per-target service lists + bash parsing fix

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| Relay services panel shows every service as "unknown" | Single hardcoded `important_services` list (companion services) used for both `--target companion` and `--target relay` | Split into `COMPANION_SERVICES` / `RELAY_SERVICES`, selected by `--target` |
| `mediamtx` missing from relay services panel | Not in any service list | Added `mediamtx.service` to `RELAY_SERVICES` |
| Refresh output had spurious extra lines | `$(systemctl is-active "$s" 2>/dev/null \|\| echo unknown)` — `is-active`/`is-enabled` print a status word AND exit non-zero (e.g. `failed`, `inactive`), so the `\|\|` fallback still ran | Rewrote as `a=$(systemctl is-active "$s" 2>/dev/null); a=${a:-unknown}` |

Verified live: `services refresh --target relay` → 20 clean lines, `--target companion` → 19 clean lines.

### FlyViewCustomLayer.qml — shutdown/reboot acknowledgement

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| Companion/Relay Restart/Shutdown gave no feedback — user had to keep pressing the button | `_confirm(title, msg, cmd)` called `PXLABSRunner.run(cmd)` directly, bypassing `_runPanelCmd`/`_panelStatus` | `_confirm` now takes a `statusMsg` arg and routes through `_runPanelCmd`; `onCommandFinished` shows "✓ Shutdown command sent" / "✓ Reboot command sent" |

Verified live on hardware — "worked perfectly". Camera switch quick-buttons (front/bottom/split) still call `PXLABSRunner.run()` directly and bypass abort-and-retry — open issue (see DEVELOPMENT.md §9 Bug A).

### CompanionControl.qml — camera resolution/FPS/format dropdowns

Previously: free-text Resolution/FPS fields + hardcoded MJPG/UYVY Format dropdown, required
manually copying values from "Query Details" output.

Added `_parseCameraQuery()` / `_applyCameraQuery()` — parses `vision_config_manager
list-details` into a format → resolution → fps map plus the camera's current values, and
populates three cascading `QGCComboBox`es (Format, Resolution, FPS) pre-selected to the
active values. Works for any device in the Device dropdown.

---

## SSH / Config Storage

- SSH config JSON: `build_clean/Release/config/ssh_config.json` (auto-created by `config set`)
- Passwords: Windows keyring, service = `"Drone-Control"`, account = username
- Companion SSH: `roz@10.5.6.101:2222` (via relay tunnel) or `roz@10.5.5.87:22` (direct WFB)
- Relay SSH: `vind-admin@10.5.6.101:22`
