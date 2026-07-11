# WFB Config Editor — Feature Doc & Session Notes (2026-07-11, rev 2)

Safe editing of `wifibroadcast.cfg` on companion (drone) and relay (ground) from the
G-Control QGC page **Settings → WFB Config**.

## How it works

```
QGC WFBConfig.qml → Pxlabs.{companion|relay}.wfbCfg*() → pxlabs_cli.py wfb-config …
    → SSH → /usr/local/sbin/wfb-cfg-apply (on device)
        backs up cfg → installs new → restarts wfb unit →
        waits ≤60 s for /run/wfb-cfg-confirm (touched by ground)
        → no confirm ⇒ AUTO-ROLLBACK to backup + restart   ← the safety net
```

- Unit auto-detection handles **standalone AND cluster**: only template instances
  (`wifibroadcast@*`, `wifibroadcast-cluster@*`) in `running` state are considered —
  the oneshot `wifibroadcast.service` ("active exited" in both modes) is excluded.
- Verified live: companion=`wifibroadcast@drone`, relay(cluster)=`wifibroadcast-cluster@gs`.
- Both watchdog paths live-tested on relay: confirm-keep ✓, timeout-rollback ✓.
- `Restore Default Config` applies `/etc/wifibroadcast.cfg.default` (pre-existing baselines).

## Parameter tiers

| Tier | Params | Rule |
|---|---|---|
| TIER1 (safe) | mcs_index, txpower, stbc, ldpc, fec_k/n per stream | Apply to ONE side; the other side adapts. Video/downlink params → target **Companion** (drone is the video TX). Uplink params → target Relay. |
| TIER2 (danger) | wifi_channel, bandwidth | MUST match BOTH ends. Mismatch = permanent link loss. UI locks them until Check Secondary passes; CLI needs `--danger-ack` + reachable secondary. |

## UI answers (user questions 2026-07-11)

- **Load Current vs View Full Config:** Load Current fetches the tunable params and fills
  the form (and sets the diff baseline). View Full Config just dumps the whole cfg text
  into the output box, read-only, for inspection.
- **Why channel/bandwidth greyed:** intentional — enabled only after "Check Secondary Link"
  succeeds (recovery path exists). Secondary is currently unconfigured ⇒ always locked.
- **Apply is one-side-only** by design (see tiers). Only channel/bandwidth ever need both.

## Apply-to-both (implemented 2026-07-11 rev 2 — NEEDS LIVE TEST)

Per user decision, ALL changes apply to BOTH sides so configs stay identical; the sole
exception is **wifi_txpower** (per-side: drone thermal/battery vs ground amp).

- CLI: `wfb-config set-both --params … [--danger-ack] [--timeout N]` (no --target).
  N = relay watchdog + confirm window (default 60); companion watchdog = 2·N+60.
  Rejects wifi_txpower. TIER2 still needs --danger-ack + reachable secondary.
- Matched-ends guarantee: reads+edits BOTH cfgs up front (aborts before touching
  anything on error) → apply companion UNCONFIRMED → apply relay → wait for companion
  (polls primary AND secondary routes — during a channel change primary only returns
  after relay flips) → confirm companion → confirm relay. Any failure = no confirms =
  both watchdogs roll back. If relay confirm alone fails, companion is auto-reverted
  to its original cfg (`MISMATCH_DANGER` printed if even that fails).
- API: `Pxlabs.wfbCfgSetBoth(params, dangerAck, timeoutS)` (top-level, node-agnostic).
- QML: main button = "Apply to Link (both ends)" (danger passes timeout 120 → relay
  window 120, companion watchdog 300); "Apply TX Power → <target>" per-side;
  target combo = view/load only; on success applied values fold into `_loaded`.

## Auto-load + secondary UI (implemented 2026-07-11 rev 2)

- `Component.onCompleted` runs `_loadParams()`; target switch clears `_loaded` and
  reloads; both Apply buttons disabled until `_cfgLoaded`. "Load Current" → "Reload".
- Secondary IP/port fields + Save in the danger section (via `Pxlabs.configSet`),
  prefilled from `config show` JSON; Save clears `_secondaryOk` so the route must be
  re-checked.

## Accepted limitations (user decision 2026-07-11: leave as is)

- set-both's companion confirm window is capped by the RELAY timeout (~N−15 s: 45 s
  safe / 105 s danger). A slow tunnel re-form past that aborts a good change → full
  rollback wait (companion 2N+60: live-observed 300 s after a danger apply was
  orphaned by closing QGC — watchdog recovery verified working on real hardware).
- Narrow race: relay confirm landing just after its watchdog fires would print
  APPLIED_BOTH with the relay actually rolled back. Fix if ever needed: re-read relay
  cfg after confirm and auto-revert companion on mismatch.

## KNOWN ISSUES / NEXT SESSION TODO

1. ~~LIVE-TEST set-both~~ **DONE 2026-07-11**: MCS 1→2→1 via CLI, APPLIED_BOTH both
   runs, both ends verified matched each time; units auto-detected correctly. Combined
   with the orphaned-apply incident (relay + companion rollbacks), every choreography
   path is live-proven except a TIER2 happy path (needs secondary route). Also still
   open: how the bandwidth combo got unlocked before the incident — re-check the
   _secondaryOk gate.
2. Phase-1 monitor integration into QGC: toolbar chip `LINK % · AIR %` from a small C++
   TCP client on the 8103 JSON feed. (Full QML panel = Phase 2. PyQt5 monitor at
   `E:\wfb-link-monitor` stays the deep-debug tool.)
3. Relay clock wrong (no NTP, shows March) — fix someday; makes watchdog logs confusing.
4. P2P PC↔relay link intermittently degrades (1 s RTT, SSH timeouts) — Bug C territory.

## Gotchas (for future changes)

- QGC invokes `tools\pxlabs_cli.exe` (frozen) by DEFAULT, not the .py! After changing
  pxlabs_cli.py, rebuild the exe:
  `cd E:\qgc-pxlabs\tools && python -m PyInstaller pxlabs_cli.spec --distpath E:/qgc-pxlabs/build_clean/Release/tools --workpath E:/qgc-pxlabs/build_pyinstaller_work --noconfirm`
  (forward slashes from bash; close G-Control first or rename the locked exe aside).
- `sudo -S cmd1 || cmd2` splits outside sudo — wrap compound commands in `bash -c '…'`.
- wfb-cfg-apply refuses NEW==CFG same-path (cp same-file error) — always apply from /tmp.

*See also: WFB_LINK_TELEMETRY.md (link telemetry reference), ARCHITECTURE.md.*
