# WFB Config Editor — Feature Doc & Session Notes (2026-08-08, rev 3)

Safe editing of `wifibroadcast.cfg` on companion (drone) and relay (ground) from the
G-Control QGC page **Settings → WFB Config**, plus live radio tuning that never
touches disk.

> **rev 3 supersedes the rev 2 "keep both configs identical" model.** That model was
> wrong for the RF parameters — see *The model* below. Channel and bandwidth are the
> only settings that must match both ends.

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

## The model — split by who transmits

`stbc`, `ldpc`, `mcs_index`, `short_gi` and `bandwidth` in `[base]` are **transmit-only
radiotap flags**. `master.cfg` labels them exactly that ("Radiotap flags for TX"), and
`services.py` only ever passes `-S/-L/-M/-B/-G` to `wfb_tx`, never to `wfb_rx`. The
running relay proves it:

```
wfb_rx -p 0   -c 10.5.6.50 -u 5600 ...          ← video downlink RX: no radio args at all
wfb_tx -p 144 ... -B 20 -G long -S 0 -L 0 -M 1  ← mavlink uplink  (0x90)
wfb_tx -p 160 ... -B 20 -G long -S 0 -L 0 -M 1  ← tunnel  uplink  (0xa0)
```

So **the drone's values own the downlink and the relay's own the uplink.** They do not
need to match, and forcing them to (as rev 2 did) pushes the drone's radio settings onto
a ground station whose cards may not support them.

FEC is likewise TX-side only — *"Rx will get FEC settings from session packet"*. The
ground station runs **no video TX at all** (`gs_video` is `udp_direct_rx` with
`stream_tx: None`), so `video.fec_k/fec_n` on the relay is inert and the UI omits it.

| Scope | Params | Rule |
|---|---|---|
| Drone TX (downlink) | `base.stbc/ldpc/mcs_index/short_gi`, `common.wifi_txpower`, `video`+`mavlink`+`tunnel` FEC | Companion only. Never copied to the relay. |
| Ground TX (uplink) | `base.stbc/ldpc/mcs_index/short_gi`, `common.wifi_txpower`, `mavlink`+`tunnel` FEC | Relay only. No video FEC — the GS never transmits video. |
| Link-wide (DANGER) | `common.wifi_channel`, `base.bandwidth` | MUST match BOTH ends. Mismatch = permanent link loss. UI locks them until Check Secondary passes; CLI needs `--danger-ack` + reachable secondary. |

`base.stbc` is a **spatial-stream count, 0–3**, not a boolean — `init_radiotap_header`
throws `Unsupported HT STBC type` above 3. (The CLI wrongly clamped it to 0–1 until rev 3.)

## Standalone vs cluster

Cluster mode does **not** ignore `stbc`/`ldpc`/`mcs_index`. The relay runs
`wfb_tx -d` (DISTRIBUTOR), which builds the radiotap header via `init_radiotap_header()`
and hands it to `RemoteTransmitter`; cluster nodes run `wfb_tx -I <port>` (INJECTOR),
whose usage line accepts **no radio options at all** and simply injects the bytes it
receives.

The real constraint is therefore: **one radiotap header is shared by every cluster node
and cannot be set per node.** The least capable card decides what is safe. With a mixed
cluster (EU card + CPE610/ath9k) keep STBC and LDPC off unless a live test proves
otherwise — which is why the relay already ships `stbc = 0, ldpc = 0`.

What cluster mode *does* silently drop is **TX power**: `cluster.py` emits
`iw dev … set txpower` only `{% if txpower[wlan] not in (None, 'off') %}`, and the
CPE610 node declares `'wifi_txpower': None`. Editing `common.wifi_txpower` moves the
relay's local card and never reaches that node.

The UI reads the current mode from `Pxlabs.relay.wfbRefresh()` (the `SA:`/`CA:` lines)
and shows the cluster warning only when it applies.

## Live tuning — `wfb_tx_cmd` (rev 3)

`wfb_tx` exposes a UDP control port with `CMD_SET_RADIO`/`CMD_GET_RADIO`. The shipped
`/usr/bin/wfb_tx_cmd` (present on both devices) drives it:

```
wfb_tx_cmd <control_port> set_radio [-B bw] [-G gi] [-S stbc] [-L ldpc] [-M mcs] [-N nss] [-V]
wfb_tx_cmd <control_port> get_radio
```

This rebuilds the radiotap header of a **running** `wfb_tx` — no config edit, no service
restart, and a unit restart puts the cfg values back. It works in cluster mode too
(the distributor has the same `update_radiotap_header`). Use it to find out what the
cards actually support before committing anything to disk.

```
pxlabs_cli wfb-config radio-get --target relay
pxlabs_cli wfb-config radio-set --target relay --stbc 1 --revert-after 30
```

`radio-set` arms a detached revert watchdog on the device **before** applying, then
applies, then requires the ground to re-reach the device and touch
`/run/wfb-radio-confirm`. If the change kills the link the confirm never lands and the
device restores the previous values by itself.

**Control ports are ephemeral** (`control_port = 0` ⇒ auto-allocated). They are
discovered by scraping the journal for `use wfb_tx … control_port N`. To make this
deterministic, pin `control_port` per stream in `wifibroadcast.cfg` — `master.cfg`
documents exactly this use ("Override in tx sections if you want to manually control
wfb_tx processes via wfb_tx_cmd utility").

## Hardware reality (measured 2026-08-08, `ethtool -i`)

| Node | Interface | Driver |
|---|---|---|
| Companion | `wlx782288d993c0`, `wlx782288d98f91` | `rtl88x2eu` (EU) ×2 — used by WFB |
| Companion | `wlx8c86dd5beed9` | `rtl88xxau_wfb` (AU) — not used by WFB |
| Relay | `wlx00c0cab6db3b` | `rtl88xxau_wfb` (**AU**) |

Two things the configs get wrong:

- The relay cfg comments its card as `(8812eu)`; it is actually the **AU** driver.
- The relay sets `wifi_txpower = 3000` (positive = EU convention). `master.cfg` says AU
  expects **negative** (`-3000` for 30 dBm). **Suspect — verify.**

The drone's video runs through `udp_proxy` across its two cards, so it already has
**multi-card TX diversity** (best card chosen by RSSI). STBC is a separate, chain-level
mechanism layered on top of that.

**LDPC:** wfb-ng **25.4.27** (the version on the devices) *still* says
`Currently available only for 8812au`, and upstream's `[bind_base]` uses
`stbc = 0 / ldpc = 0` — *"Use settings compatible with all wifi cards to avoid deadlock"*.
Moving to EU-only therefore does **not** unlock LDPC; treat it as unverified and measure
it with `radio-set` before saving it anywhere.

## Live incident 2026-07-11 (validates the watchdog chain)

User applied bandwidth 40 via the UI, closed QGC mid-apply → `set-both` orphaned, no
confirms. Relay auto-rolled back; companion sat out its full 300 s danger watchdog then
rolled back; link self-recovered. Watchdog recovery works in production.

## Accepted limitations (user decision 2026-07-11: leave as is)

- `set-both`'s companion confirm window is capped by the RELAY timeout (~N−15 s: 45 s
  safe / 105 s danger). A slow tunnel re-form past that aborts a good change → full
  rollback wait (companion 2N+60).
- Narrow race: relay confirm landing just after its watchdog fires would print
  APPLIED_BOTH with the relay actually rolled back. Fix if ever needed: re-read relay
  cfg after confirm and auto-revert companion on mismatch.

## On-device script — wfb-cfg-apply (source of record)

- Installed at `/usr/local/sbin/wfb-cfg-apply`, **755 root:root**, byte-identical on
  companion AND relay (verified by fetch+diff 2026-07-12).
- Reference copy in THIS repo: `tools/reference/wfb-cfg-apply` — if the devices and this
  copy ever disagree, the devices win; re-fetch before editing.
- Log on device: `/var/log/wfb-cfg-apply.log`. Confirm file: `/run/wfb-cfg-confirm`.
  Backup: `/etc/wifibroadcast.cfg.bak`.
- **USER TODO (device repos):** add `/usr/local/sbin/wfb-cfg-apply` to the companion
  and relay config repos + their auto-sync, commit, and tag a new release on both.
  Do it ON THE DEVICES via the normal gateway flow — NEVER push those repos from the PC.

## Gotchas (for future changes)

- QGC invokes `tools\pxlabs_cli.exe` (frozen) by DEFAULT, not the .py! After changing
  pxlabs_cli.py, rebuild the exe:
  `cd E:\qgc-pxlabs\tools && python -m PyInstaller pxlabs_cli.spec --distpath E:/qgc-pxlabs/build_clean/Release/tools --workpath E:/qgc-pxlabs/build_pyinstaller_work --noconfirm`
  (forward slashes from bash). If G-Control holds the exe, rename it aside rather than
  killing the app — Windows allows renaming a running binary.
- `sudo -S cmd1 || cmd2` splits outside sudo — wrap compound commands in `bash -c '…'`.
- wfb-cfg-apply refuses NEW==CFG same-path (cp same-file error) — always apply from /tmp.
- **`_sudo_wrap` only rewrites commands starting with `sudo `**, turning them into
  `sudo -S` with the password piped in. Never add `-n` — sudo then refuses to read it.
- **The relay's login user is not in `adm`/`systemd-journal`**, so `journalctl` returns
  *nothing at all* rather than erroring. Anything reading the relay journal needs `sudo`.
- Dev `pxlabs_cli.py` with no `E:\qgc-pxlabs\config\ssh_config.json` falls back to
  hardcoded defaults with a **stale relay IP**. The authoritative config is
  `build_clean\Release\config\ssh_config.json`.
- **`cmd.exe /c` from Git Bash gets its `/c` path-mangled by MSYS** — cmd opens
  interactively and does nothing, while still exiting 0. Use `cmd.exe //c "E:\…\do_build.bat"`.

*See also: WFB_LINK_TELEMETRY.md (link telemetry reference), ARCHITECTURE.md.*
