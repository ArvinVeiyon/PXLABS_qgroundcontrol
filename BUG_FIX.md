# BUG_FIX.md — G-Control / PXLABS QGC

Backlog of architecture-level improvements and bug fixes. Captured 2026-07-08. Work each item in detail later.

---

## ✅ RESOLVED 2026-07-11 — control-plane API facade (A1 option 2)

Built the **`Pxlabs` C++ facade** — the full "command queue + priority" version of A1 (not just the correlation-ID option). Additive; legacy `PXLABSRunner` singleton left registered for rollback.

- **New C++:** `src/Utilities/PXLABSCommandBus.{h,cc}` (queued engine + `PXLABSRequest` correlation object) and `PXLABSApi.{h,cc}` (`Pxlabs` singleton + `PXLABSCompanionNode`/`PXLABSRelayNode`). Registered in `QGCApplication.cc`.
- **Bus behaviour:** `enqueue()` never rejects → returns a `PXLABSRequest`; per-request signals (`outputChanged`/`succeeded`/`failed`); **Interactive priority preempts a running Background poll**; Background polls coalesce; args passed as `QStringList` straight to QProcess (no shell).
- **QML:** all 6 files migrated to the facade (55 call sites). Deleted every `pxlabs_bg_active` mutex, `_bgRetryArgs` retry timer, `_statusCheckPending` queue, `_camQueryActive`/`_svcRefreshActive` flag-routing, and the now-pointless Abort buttons.

**Bugs closed:**
- **A1** ✅ — request correlation + queue; flag/mutex/retry machinery deleted repo-wide.
- **B1** ✅ — camera quick-buttons now enqueue interactively and **preempt** the background poll; no more silent rejection.
- **B5** ✅ — `QStringList` args end space-splitting (old `PXLABSCommandRunner.cc:79`).
- **B4** ⚠️ partial — QGC side no longer involves a local shell and passes discrete args, but `tools/pxlabs_cli.py` still needs `shlex.quote()` on the **remote** command (server-side, not this repo).

**Also fixed (blocker):** `cmake/Git.cmake` version parse — `git describe` tag `PXLABS-v3.0.0` → stripped to `PXLABS-3.0.0` and fed to `project(VERSION)`, which CMake rejects. Now extracts numeric `X.Y.Z` via regex (display string `QGC_APP_VERSION_STR` unchanged). This broke *any* clean reconfigure, not just this change.

Build verified: `BUILD_EXITCODE=0`, G-Control.exe relinked.

---

## Architecture-level improvement (root cause of most UI bugs)

### A1 — Single shared runner, six callers, no request correlation
**Problem:** `PXLABSRunner` is a QML **singleton** (`src/QGCApplication.cc:311`) wrapping ONE `QProcess` with a single `_running` guard (`src/Utilities/PXLABSCommandRunner.cc:68`). Six QML files call `.run()` on it (FlyView toolbar's 2 poll timers, FlyViewCustomLayer's 10 calls, CompanionControl, RelayControl, ConnectionControl, PXLABSSettings). The singleton's `outputReady` / `commandFinished` / `commandFailed` signals are **global**, so every panel receives every other panel's output and must guess whether a signal is its own.

**Symptoms in code (all hacks working around the missing request ID):**
- Toolbar `_statusFetch` / `_pxWifiFetch` bool flags = "is this output mine?" (`src/QmlControls/FlyViewToolBar.qml:102, 111`)
- Hand-rolled retry queue `_statusCheckPending` (`FlyViewToolBar.qml:56–58, 132`)
- Panels coordinate by writing `pxlabs_bg_active` to `saveGlobalSetting` — **on-disk settings used as an inter-component mutex** (`FlyViewToolBar.qml:50, 61, 125`)
- A user click can be silently rejected because a 60 s `wifi-temp` poll holds the single process slot (root cause of the Bug A "nothing happened" reports)

**Fix options (smallest first):**
1. **Correlation ID (~1 day):** `run(args)` → returns monotonic `int requestId`; add id to every signal (`outputReady(id, text)`, `commandFinished(id, exitCode)`). Each panel keeps its own id and ignores others'. Deletes `_statusFetch`, `_pxWifiFetch`, `pxlabs_bg_active`, and the retry-queue hack.
2. **Command queue + priority (~2–3 days):** instead of rejecting when `_running`, enqueue. Interactive clicks get higher priority than the 2 background pollers; stale queued polls are coalesced/dropped.

---

## Bugs (ranked)

### B1 — HIGH — Camera-switch quick-buttons bypass abort-and-retry (open Bug A remainder)
The 4 camera-switch buttons call `PXLABSRunner.run(...)` **directly**, so when a background poll holds the slot the click is silently rejected with no acknowledgement — user keeps pressing.
- File: `src/FlightDisplay/FlyViewCustomLayer.qml` ~810 (`front-switch`), ~818 (`bottom-switch`), ~830 (`split-front-bottom`), ~838 (`split-bottom-front`)
- Fix: route through `_runPanelCmd(args, statusMsg)` like the power buttons already do.

### B2 — HIGH (security) — SSH host keys blindly accepted
`AutoAddPolicy()` + `StrictHostKeyChecking=no` → no MITM protection on the WFB RF link.
- File: `tools/pxlabs_cli.py:117, 137, 227` (paramiko `set_missing_host_key_policy`); `:186` (ssh-terminal `StrictHostKeyChecking=no`)
- Fix: ship a known_hosts with pinned companion/relay host keys; TOFU on first run, then `RejectPolicy`.

### B3 — MEDIUM — Process-per-command over a 7 Mbps lossy link
Every button and every poll spawns `pxlabs_cli.exe` → fresh paramiko TCP+auth handshake (10 s timeout) over the WFB tunnel. Two timers (`wifi-temp` @60 s, `status` @120 s) cause constant reconnects competing with MAVLink/video on the same radio (the bandwidth `block-traffic.service` exists to protect).
- Scope: whole CLI invocation model
- Fix: persistent local agent holding ONE open SSH transport, multiplexing channels; UI talks to it over a local socket. Pairs naturally with A1's queue.

### B4 — MEDIUM (security) — Shell injection surface in camera params
`device` / `resolution` / `fps` / `format` interpolated unescaped into the remote shell command string.
- File: `tools/pxlabs_cli.py:310` (`set-cam-params`), also `:209, 217`
- Fix: `shlex.quote()` each interpolated value.

### B5 — LOW — C++ splits args on spaces
`args.split(' ', SkipEmptyParts)` breaks any argument containing a space into separate argv; fragile QML→C++ contract.
- File: `src/Utilities/PXLABSCommandRunner.cc:79`
- Fix: pass a `QStringList` from QML, or use quote-aware splitting.

### B6 — LOW — Stale default IPs
`_default_config` uses `10.5.6.100` for both companion and relay, but `ARCHITECTURE.md` documents relay at `10.5.6.101`. Harmless while `ssh_config.json` exists; wrong on a fresh install.
- File: `tools/pxlabs_cli.py:52–61`
- Fix: match documented addresses.

### B7 — OPEN (from tracker) — Bug C: no SSH tunnel health visibility
`status` only TCP-probes reachability; nothing confirms `ssh-tunnel-to-companion.service` (autossh relay:2222 → companion:22) is actually alive.
- Fix: add `systemctl is-active ssh-tunnel-to-companion.service` check + a chip/glyph in the toolbar.

---

## Suggested order
1. B1 (small, closes last piece of Bug A, visible on hardware)
2. A1 option 1 — correlation ID (deletes the flag/mutex machinery, prevents B1 recurring)
3. B4 + B5 (quick hardening while in those files)
4. B3 persistent agent (own session — larger rewrite, biggest bandwidth win)
5. B7 tunnel health

## Separate track (NOT this repo) — public-repo secret leak
Companion/Relay repos are public with real WFB keys, an ed25519 SSH private key, and sudo password `1987` recoverable from git history. Rotate secrets + privatize + purge history. See memory `project_repo_audit.md`. (QGC repo itself is clean — keyring used, no tracked secrets.)
