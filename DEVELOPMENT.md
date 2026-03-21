# G-Control — Development Journal

Full chronological record of all development work on the PXLABS QGC fork.
For a technical reference of what files changed and why, see `PXLABS_CHANGES.md`.

---

## Project Overview

**G-Control** is a customised build of QGroundControl v5.0.8 for the Vind-Roz drone system.
It adds a companion computer control panel, relay station management, WFB-NG mode switching,
SSH terminal access, and Air-TX temperature monitoring — all without modifying any native QGC code.

| Item | Detail |
|------|--------|
| Base | QGroundControl v5.0.8 (tag `qgc-v5.0.8-base`) |
| Dev branch | `PXLABS-v2.1-integration` |
| GitHub | `https://github.com/ArvinVeiyon/PXLABS_qgroundcontrol` |
| Build output | `E:\qgc-pxlabs\build_clean\Release\G-Control.exe` |
| Installer | `E:\qgc-pxlabs\installer\G-Control-Setup-v<version>.exe` |
| Companion | Vind-Roz RPi5 — SSH 10.5.6.101:2222 (user: roz) |
| Relay | Vind-Rly RPi5 — SSH 10.5.6.101:22 (user: vind-admin) |

---

## Release History

| Version | Date | Tag | Branch | Highlights |
|---------|------|-----|--------|------------|
| v2.1.0 | 2026-03-20 | `PXLABS-v2.1.0` | `release/PXLABS-v2.1` | First stable QGC integration release |
| v2.2.0 | 2026-03-22 | `PXLABS-v2.2.0` | `release/PXLABS-v2.2` | Resizable panel, WFB stale-green fix, camera-params, Windows installer |

---

## Session Log

---

### Session 1 — 2026-03-20 (Initial Integration)

**Goal:** Port Drone_Control v2.1 PyQt5 standalone app features into native QGC.

**What was built:**

- `PXLABSCommandRunner.h/.cc` — C++ QProcess wrapper singleton (`PXLABSRunner`) registered to QML as `QGroundControl.PXLABS`. Runs `python pxlabs_cli.py <args>`, emits `outputReady`, `commandFinished`, `commandFailed`.
- `ConnectionControl.qml` — SSH config page (companion IP/port/user, relay IP/port/user). Periodic connection check settings. Air-TX temp poll settings.
- `PXLABSSettings.qml` — Python path + CLI path config + Test CLI button.
- `CompanionControl.qml` — Camera switch (Front/Bottom/Split), Camera Device Advanced (query full detail, set params), System (reboot/shutdown), Services list.
- `RelayControl.qml` — WFB mode (standalone/cluster), NIC config, System, Services.
- `FlyViewCustomLayer.qml` — Right-edge expandable System Control panel with WFB mode buttons, SSH terminal buttons, power management. Pull tab shows WFB mode glyph (◉/⬡/⊙) when closed.
- `FlyViewToolBar.qml` (modified) — Air-TX chip (temp), Comp●/Relay● connection status chips.
- `tools/pxlabs_cli.py` — SSH CLI bridge. All companion/relay/services/status/config commands.
- `build_pxlabs.bat` / `deploy_dlls.bat` / `Launch-GControl.bat` — build + deploy + launch scripts.

**Key bugs fixed during integration:**
- `IndentationError` in pxlabs_cli.py from orphaned action line
- UnicodeEncodeError on WFB ● character under Windows cp1252 — fixed with `reconfigure(encoding="utf-8")`
- SSH terminal: `start cmd /k "ssh..."` treated quoted string as program name — removed quotes
- `run_cmd` buffering under QProcess — added `flush=True`
- `_onFinished` race: buffered output arrived after QML cleared fetch flag — drain stdout/stderr before emitting `commandFinished`
- Air-TX temp: interface detection now reads `/etc/default/wifibroadcast` first, falls back to procfs

**Released:** v2.1.0 tagged and pushed.

---

### Session 2 — 2026-03-21 (Bug Fixes + UI Polish)

**Goal:** Fix reported bugs, improve UI, add missing features.

**Bugs fixed:**

| Bug | Fix |
|-----|-----|
| Stale green connection status after disconnect | Removed `loadGlobalSetting` persistence for `_wfbMode`; start as `""`, fetch on panel open only |
| Periodic busy indicator (spinner appearing randomly) | Isolated `_busy` per-command; added `bgRetryTimer` for background abort/retry |
| Service list rendering issues (not showing / duplicating) | Fixed dynamic `_svcNames` population timing |
| Panel sizing wrong on startup | Fixed saved geometry restore order |
| WFB mode not syncing correctly | Rewrote parse logic: `SA:active/inactive` + `CA:active/inactive` lines |
| Panel resize horizontal-only and vertical-only not working | Raised `leftResizeHandle` + `bottomResizeHandle` from z:5 → z:6; added `preventStealing: true`. Root cause: Flickable inside `rpContent` at z:5 was stealing mouse grab on vertical axis |

**Features added:**

- **Top-edge resize handle** — new `topResizeHandle` MouseArea; math: `newY = pressY + dy`, `newH = pressH - dy` (bottom fixed, top moves)
- **camera-query full detail** — changed from `v4l2-ctl --list-formats-ext` to `sudo vision_config_manager list-details {device}` (matches v1.4 standalone app)
- **camera-params action** — new CLI action: `companion camera-params --device --resolution --fps --format` → calls `vision_config_manager set-cam-params`
- **Capture section removed** from CompanionControl (QGC has native capture)
- **"Apply Camera" button removed** from Camera Device Advanced (was redundant with camera switch)
- **"Set Params" → "Apply"** rename (matches v1.4 app naming)
- **Companion page icon** changed from `camera.svg` → `servers.svg` (companion sits on air unit, not a camera)
- **PXLABS brand chip** added to toolbar between Air-TX and PX4 logo

**PXLABS_CHANGES.md** updated with full v2.2 changes.

**Released:** v2.2.0 tagged (`PXLABS-v2.2.0`), pushed, `release/PXLABS-v2.2` branch created.

---

### Session 3 — 2026-03-22 (Windows Installer)

**Goal:** Build a distributable `G-Control-Setup.exe` — zero dependencies on target machine.

**What was built:**

#### Step 1 — PyInstaller bundle (`pxlabs_cli.exe`)

- Spec at `tools/pxlabs_cli.spec` — onefile, includes paramiko + cryptography + keyring
- Output: `build_clean\Release\tools\pxlabs_cli.exe` (~15–17 MB)
- **Bug 1 — `xml` excluded:** `pkg_resources` needs `plistlib` which needs `xml`. Removed `xml` from `excludes` list.
- **Bug 2 — pycparser broken (`optimize=2`):** PLY stores grammar production rules in function docstrings. `optimize=2` strips all docstrings → pycparser can't build parser tables → cffi fails → cryptography fails → paramiko fails → every SSH command fails silently. Fixed: `optimize=2` → `optimize=0`.
- **Bug 3 — wrong config path when frozen:** `__file__` in a PyInstaller onefile frozen exe points to the temp `_MEI*` extraction dir, not the real install location. Fixed: added `sys.frozen` check:
  ```python
  if getattr(sys, "frozen", False):
      ROOT = Path(sys.executable).resolve().parents[1]
  else:
      ROOT = Path(__file__).resolve().parents[1]
  ```

#### Step 2 — PXLABSCommandRunner update

- Default `cliPath` changed from `tools/pxlabs_cli.py` → `tools/pxlabs_cli.exe`
- `run()` now auto-detects: `.exe` → runs directly (no Python needed); `.py` → invokes via `python` (dev workflow unchanged)
- Error message updated: "check Python path" → "check CLI path"

#### Step 3 — NSIS installer (`G-Control-Setup.nsi`)

- Script at `installer\G-Control-Setup.nsi`; helper `installer\EnvVarUpdate.nsh` bundled locally
- Packages entire `build_clean\Release\` (excluding `lib\` static libs and `.py` source)
- Installs to `C:\Program Files\G-Control\`
- Sets `GST_PLUGIN_PATH` in HKCU (user environment) — no reboot required
- Creates Start Menu + Desktop shortcuts
- Registers in Add/Remove Programs
- **Bug — 32-bit registry hive:** NSIS default writes to `WOW6432Node` even for 64-bit apps. Fixed: added `SetRegView 64`.
- `SetOverwrite off` for `config\ssh_config.json` — user SSH credentials survive reinstall
- Uninstall deliberately keeps `config\` folder

**Output:** `installer\G-Control-Setup-v2.2.0.exe` (~117 MB LZMA compressed)

---

## Architecture Notes

### How CLI commands flow

```
QML (e.g. CompanionControl.qml)
  └─ PXLABSRunner.run("companion front-switch")
       └─ PXLABSCommandRunner.cc
            ├─ if cliPath ends with .exe → run pxlabs_cli.exe front-switch directly
            └─ else → python pxlabs_cli.py companion front-switch
                 └─ pxlabs_cli.py
                      └─ paramiko SSH → companion 10.5.6.101:2222
                           └─ sudo vision_config_manager /dev/video0
```

### Signal routing (multi-command isolation)

`PXLABSRunner` emits `outputReady(text)` and `commandFinished(exitCode)` to ALL connected QML pages.
Each page uses a boolean flag (`_statusFetch`, `_pxWifiFetch`, etc.) to route signals to the correct handler.
Check the flag first in every `Connections` handler.

### WFB mode detection

`relay wfb refresh` output is parsed for:
- `SA:active` + `CA:inactive` → "standalone"
- `CA:active` + `SA:inactive` → "cluster"
- both active → defaults to "standalone"

Mode is never persisted to `QGroundControl.saveGlobalSetting` — always fetched fresh on panel open.

### Resize handle z-ordering

System Control panel has 4 resize handles (left, right corner, bottom, top).
All at z:6. The `rpContent` Flickable is z:0 but its mouse grab propagates up to z:5 level.
`preventStealing: true` is set on left and bottom handles as belt-and-suspenders for vertical drag.

### PyInstaller frozen exe path resolution

Always use `sys.executable` (not `__file__`) to find files next to the exe when frozen.
`__file__` points to the temp `_MEI*` extraction dir which is deleted after the process exits.

---

## Build & Deploy Reference

```bat
# Full rebuild from CMD (not bash — pause command blocks bash)
E:\qgc-pxlabs\build_pxlabs.bat

# No-pause wrapper usable from bash/Claude Code
cmd /c "E:\qgc-pxlabs\do_build.bat"

# Rebuild CLI exe only
cd E:\qgc-pxlabs\tools
python -m PyInstaller pxlabs_cli.spec --distpath E:\qgc-pxlabs\build_clean\Release\tools --workpath E:\qgc-pxlabs\build_pyinstaller_work --noconfirm

# Test CLI exe before packaging
E:\qgc-pxlabs\build_clean\Release\tools\pxlabs_cli.exe config show
E:\qgc-pxlabs\build_clean\Release\tools\pxlabs_cli.exe --help

# Rebuild installer
cd E:\qgc-pxlabs\installer
"C:\Program Files (x86)\NSIS\makensis.exe" G-Control-Setup.nsi

# Launch (dev)
E:\qgc-pxlabs\Launch-GControl.bat
```
