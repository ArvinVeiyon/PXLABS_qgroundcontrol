# BUG_FIX — Companion + Relay (WFB-NG focus)

Findings from review of `Companion_Computer_Pxlabs` and `Relay_Station_Pxlabs` on 2026-07-08.
Line refs are against the committed `System_files/...` backups in each repo. Work later in detail.

---

## ⭐ WFB-NG — improvements you asked for

### W1 — ~~CRITICAL BUG: channel mismatch~~ → RESOLVED: NOT a live bug, stale GitHub mirror only (verified 2026-07-10)
Original finding was a **static diff of two committed repo files**:
- Companion `System_files/etc/wifibroadcast.cfg:34` → `wifi_channel = 161`
- Relay `System_files/etc/wifibroadcast.cfg:34` → `wifi_channel = 157`

**Verified on live hardware over WFB (2026-07-10) — the link is fine, both radios are on 161:**
| Source | Channel |
|--------|---------|
| Relay `vind-rly` live `/etc/wifibroadcast.cfg` | **161** ✅ |
| Relay local `~/codex-relay` committed | **161** ✅ |
| Companion `Vind-Roz` live (link up, 12–18 ms) | **161** ✅ |
| **GitHub `Relay_Station_Pxlabs` mirror** | **157** ← STALE, the only wrong copy |

**Root cause = git-gateway lag, not RF.** The relay has no internet; its `/etc` is committed to a *local* repo `~/codex-relay`, and the **companion** relays it to GitHub via `scripts/relay_git_sync.sh` (fetch relay→mirror over WFB, then `git push master --tags`). GitHub HEAD is stuck at `ae857c9`; the relay is **2 commits ahead** (`c8b519e`, `01aa9ab`, both "Auto-sync 2026-03-15") which carry the 157→161 bump. `ae857c9` is an ancestor of `01aa9ab`, so it's a clean **fast-forward** — no divergence.

**Fix (repo hygiene only, no live action):** run `bash ~/codex-work/scripts/relay_git_sync.sh` on the companion when it has internet → fast-forwards GitHub `ae857c9→01aa9ab`, mirror reads 161. Attempted 2026-07-10; companion fetched OK but GitHub push failed (`rc=128`) — companion sealed inside rover, no internet. Retry when opened. (Note: `ARCHITECTURE.md` doc still says 157 — update doc to 161 too.)

**✅ FULLY CLOSED 2026-07-11 (verified from GitHub):** the gateway sync ran — relay `origin/master` fast-forwarded `ae857c9 → 465eac8` (relay v1.0.4). Both committed configs now read `wifi_channel = 161` (`companion System_files/etc/wifibroadcast.cfg:34`, `relay :34`). Mirror is no longer stale. QGC-repo docs also fixed: `ARCHITECTURE.md` + `DEVELOPMENT.md` ch157 → ch161 (todo #5). Nothing left on W1.

**Lesson:** a committed-file diff proves *repo drift*, not a live outage. The real class-bug is that the two nodes sync to git independently with no coordination (see C2 / roadmap #1 config-as-code) — that's what let the mirror go stale. Do NOT "fix" by pushing from a PC clone: it would fork history off `ae857c9` and break the companion's fast-forward gateway push.

### W2 — ✅ RESOLVED 2026-07-11 — dual-NIC config now committed (was drift)
`system_companion.md:527, 817` (release v1.0.9, commit `ea17fe4`) describe moving video to `service_type = udp_proxy` with **two NICs** for TX across both adapters, but the committed config previously shipped single-adapter (`udp_direct_tx`, one NIC) — pure drift.

**Verified fixed on `origin/master` (companion v1.1.0):**
- `wifibroadcast.cfg:58` → video stream `service_type = 'udp_proxy'` ✅
- `etc/default/wifibroadcast:11` → `WFB_NICS="wlx782288d993c0 wlx782288d98f91"` (both NICs, uncommented) ✅
- Relay side reconciled too (commit `9ee8e03` "Fix cluster config"); relay video correctly `udp_direct_rx`.

Config now matches the docs — the dual-NIC improvement is actually deployed. (W4 `mirror` vs distribute is the remaining per-goal choice, still `False`.)

### W3 — Throughput/latency tuning levers (currently very conservative)
Both sides: `mcs_index = 1` (BPSK 1/2, ~7 Mbps), `short_gi = False`, `bandwidth = 20`.
- **MCS:** MCS1 is max-robustness/min-rate. If your link margin allows, MCS2–3 roughly doubles video headroom. Best done as a tested step, not blind.
- **short_gi = True** → ~11% throughput for free (small robustness cost).
- **`mavlink_agg_timeout = 0.1`** (100 ms) adds up to 100 ms of control-link latency by batching MAVLink. Dropping to ~0.015–0.025 s cuts telemetry/RC lag at a minor bandwidth cost. (`wifibroadcast.cfg`, [common])
- Video FEC `k=8 n=12` (33% overhead) is reasonable; revisit only if you see video breakup under loss.

### W4 — Diversity vs distribute (`mirror`)
`mirror = False` (`wifibroadcast.cfg:81`). With multiple NICs, `mirror = True` transmits the same packets on all adapters (redundancy/range) vs `udp_proxy` which distributes (throughput). Decide per goal: range/reliability → mirror; bitrate → distribute. Pairs with W2.

### W5 — No link-quality feedback loop
There's no RSSI/packet-loss surfaced to the GCS and no adaptive bitrate. WFB-NG exposes stats on `stats_port` (drone 8002 / gs 8003) and `api_port` (8102/8103). Feeding RSSI + FEC-recovered/lost counts into a G-Control chip (and eventually a simple adaptive-MCS or adaptive-video-bitrate loop) is the highest-value WFB improvement after W1/W2.

---

## Companion / Relay bugs & improvements

### C1 — HIGH (security) — WPS P2P PIN hardcoded and reused
Both P2P join scripts hardcode WPS PIN `1987` — the same value as the relay sudo password — in a public repo.
- `Relay_Station_Pxlabs/System_files/home/vind-admin/start_p2p_on_wlan0.sh` (`wps_pin any 1987`)
- `.../rely_p2p.sh` (same)
**Fix:** randomize/rotate the PIN, stop reusing the sudo password, and don't commit it. (See secret-leak track below.)

### C2 — MEDIUM — Relay sync script has no arm-safety and no secret filter
`Relay_Station_Pxlabs/scripts/system_files_sync.sh` rsyncs `--files-from` (incl. the ed25519 key + wfb keys) and auto-commits, with **no "drone armed" guard** (the companion script has one) and **no secret deny-list**. This is the mechanism that keeps re-committing secrets.
**Fix:** add a deny-list (`*.key`, `id_*`, `*ed25519*`) / gitleaks pre-commit; consider the arm-check for parity.

### C3 — LOW — Two divergent P2P scripts doing the same job
`start_p2p_on_wlan0.sh` and `rely_p2p.sh` both bring up the P2P group on wlan0 with overlapping/commented-out routing logic. Duplication invites drift.
**Fix:** consolidate to one script (systemd unit), delete the other.

### C4 — LOW — Deprecated `ifconfig` in P2P scripts
Both scripts use `ifconfig ... netmask ...` (deprecated, may be absent on minimal Ubuntu 24.04). Prefer `ip addr add 10.5.6.101/24 dev <if>`.

### C5 — Review pending — `px4_mavlink.py rm-faults`
`scripts/px4_mavlink.py` runs NuttShell over MAVLink `SERIAL_CONTROL` and has an `rm-faults` (deletes `fault_*.log` from SD). Deleting flight logs is destructive — verify it can't fire while armed / mid-flight and that pattern matching can't wipe unintended files. (Not yet deep-reviewed.)

### C6 — HIGH — Companion `mavlink.router.service` has a broken ExecStart
`Companion_Computer_Pxlabs/System_files/etc/systemd/system/mavlink.router.service:7`:
```
ExecStart=/usr/local/bin/usr/bin/mavlink-routerd
```
Two problems: (1) the path is malformed (doubled `/usr/local/bin/usr/bin/`), and (2) it passes **no `-c /etc/mavlink-router/main.conf`**. The relay unit is correct (`/usr/bin/mavlink-routerd -c /etc/mavlink-router/main.conf`). As written the companion router either fails to start (Restart=always → crash-loops) or runs with defaults and **ignores `main.conf` entirely** (wrong endpoints/ports). Confirm on hardware.
**Fix:** `ExecStart=/usr/bin/mavlink-routerd -c /etc/mavlink-router/main.conf` (verify actual binary path with `command -v mavlink-routerd`).

**Status 2026-07-10 — diagnosed, fix-ready, pending hardware apply.** Re-verified the committed backup: companion unit line 7 = `/usr/local/bin/usr/bin/mavlink-routerd` (broken); relay unit correct. Companion `main.conf` IS real and populated — UART `/dev/ttyAMA0@921600` (Pixhawk) + TCP 5760 + UDP 127.0.0.1:14550 into WFB — so the missing `-c` means the whole Pixhawk→WFB routing config is unused. **W1 lesson applies: the committed backup being wrong does NOT prove the live box is broken** — the live unit may have been hand-fixed. Must verify live with `systemctl cat mavlink.router.service` before assuming an outage. Apply script (verify-binary → backup → sed → daemon-reload → restart → status, and no-ops if live is already correct): `E:\qgc-pxlabs\fix_c6_mavlink_router.sh`. Run ON the companion, not from PC; let the companion's normal /etc git-sync gateway the commit. Blocked same as W1: companion sealed in rover, retry when opened.

**⚠️ REASSESSED 2026-07-11 — the "doubled path" is NOT a bug; C6 largely a false alarm.** The user's own `system_companion.md` documents this path as intentional: `:202` "Binary: `/usr/local/bin/usr/bin/mavlink-routerd` (unusual path — installed with bad `--prefix`, but correct and working as-is)" (also `:47, :396` + companion `memory/MEMORY.md`). So the binary genuinely lives at that doubled path — the ExecStart is correct. On the missing `-c`: `mavlink-routerd` defaults to reading `/etc/mavlink-router/main.conf` when no `-c` is given, so `main.conf` is loaded anyway. **Net: mavlink-router is working as-is; downgrade C6 to non-issue** unless a live `systemctl status`/telemetry test shows otherwise. `fix_c6_mavlink_router.sh` would actually BREAK it (rewrites the real path) — do not run.

### C7 — MEDIUM — Dead logrotate + WFB link stats persisted nowhere
`etc/logrotate.d/wifibroadcast` rotates `/var/log/wifibroadcast.log` and `/var/log/wfb_telemetry_*.log`, but `wifibroadcast.cfg` sets `log_file = None` and `binary_log_file = None` — **those files are never written**, so the rotate rules are dead and RF link stats (RSSI, FEC recovered/lost) persist nowhere. Directly blocks W5 (link-quality feedback).
**Fix:** either set `log_file`/`binary_log_file` in the cfg to the paths logrotate expects, or (better) add a WFB stats exporter reading ports 8002/8003 into the observability pipeline (see roadmap #3) and drop the dead logrotate rules.

### C8 — LOW — Doc drift: `vision_streaming` is a ROS2 node, not FFmpeg
`vision_streaming.service` ExecStart is `ros2 run vision_streaming vision_streaming_node`, but `ARCHITECTURE.md` (QGC repo) describes video as "FFmpeg H264 RTP". Update the diagram/text to match.

---

## Separate track — public-repo secret leak (both repos)
Real WFB keys (`drone.key`/`gs.key`), ed25519 SSH private key, and sudo password `1987` recoverable from git history. Rotate + privatize + purge history. Details in memory `project_repo_audit.md`. Ties to C1/C2 (the sync scripts + hardcoded PIN are how they got there).

---

## Suggested order (updated 2026-07-11 after companion v1.1.0 / relay v1.0.4)
1. ~~**W1** channel mismatch~~ — ✅ **FULLY CLOSED**: both configs on 161, mirror fast-forwarded (`ae857c9→465eac8`), QGC docs fixed.
2. ~~**W2** dual-NIC drift~~ — ✅ **RESOLVED**: companion committed `udp_proxy` + both NICs; relay cluster config fixed.
3. ~~**C6** companion mavlink-router~~ — ⚠️ **DOWNGRADED to non-issue**: doubled path is the real binary location per `system_companion.md`; default config path covers the missing `-c`. Do NOT run `fix_c6_mavlink_router.sh`. Only revisit if a live telemetry test fails.
4. **C1/C2** stop leaking secrets — ⏳ STILL OPEN: relay p2p scripts still hardcode WPS PIN `1987` (= sudo pw); `system_files_sync.sh` still rsyncs `--files-from` with no secret deny-list / arm guard. Highest remaining risk.
5. **C7 + W5** persist WFB stats → GCS chip, then adaptive bitrate — ⏳ OPEN: `log_file`/`binary_log_file = None`, logrotate rules still dead.
6. **W3/W4** tuning pass (MCS, short_gi, agg timeout) — ⏳ OPEN (optional): still `mcs_index=1`, `short_gi=False`, `mavlink_agg_timeout=0.1`.

**New operational issues logged in companion `memory/todos.md` (do after OS backup):** relay NTP/clock 14 days behind; drone `wlan0`→"Nilan" 5 GHz AP interference; GS `wfb-server` crashes with `BlockingIOError EAGAIN` (19 restarts — raise `rx_ring_size` or lower video bitrate); GS→drone uplink packet loss (check TX power).
