# ARCHITECTURE_ROADMAP — G-Control / PXLABS Vind-Roz

Path from the current bespoke system to an industrial-standard drone GCS + companion + relay + WFB-NG stack.
Captured 2026-07-08. Companion to `BUG_FIX.md` (tactical bugs) and `BUG_FIX_companion_relay.md` (WFB-NG + node bugs).

**How to read this:** the individual bugs (W1 channel mismatch, B1 button, B2 host keys, secret leaks…) are *symptoms*. This roadmap fixes the *patterns* that produce them. Sequenced by leverage.

---

## 0. The root pattern: SSH-shell-out is the control plane

> **Progress — 2026-07-11 (v3.1.0, facade):** the **GCS-side half** of the target API now exists. `PXLABSCommandRunner` (single shared QProcess singleton) is superseded by the `Pxlabs` facade + `PXLABSCommandBus`: typed operations, **request correlation**, a **priority queue** (Interactive preempts Background), and **no shell** (args as `QStringList`). This retires the singleton-contention and shell-injection symptoms on the PC side — closes `BUG_FIX.md` **A1, B1, B5** and the QGC portion of **B4**.
> **Still open (node-side half):** each command is still a fresh `pxlabs_cli.exe` → fresh SSH connection with a **stored password** + `AutoAddPolicy` (B2, B3), and there is no on-node daemon / typed RPC / auth / arm-interlock yet. The facade is the client shape those will plug into — the daemon + token/mTLS auth is the remaining Tier-0 work.

**Current state.** The GCS controls the drone/relay by spawning `pxlabs_cli.exe`, which opens a **fresh SSH connection** per command and runs `sudo systemctl …` with a **stored password**, `AutoAddPolicy` (accepts any host key), one OS process per action. ~~funneled through a single shared QProcess singleton (`PXLABSCommandRunner`)~~ → **as of v3.1.0, funneled through the `Pxlabs` facade's priority queue (correlation IDs, no shell).**

**Why it's the root cause.** Nearly every open issue descends from this one pattern:
- Singleton contention / "button did nothing" — `BUG_FIX.md` A1, B1
- MITM exposure (AutoAddPolicy + StrictHostKeyChecking=no) — B2
- Reconnect storms over a 7 Mbps lossy link — B3
- Shell-string injection surface — B4/B5
- Leaked sudo password reachable as a live control credential

**Target state — a versioned control API.** Each node (companion, relay) runs a small **daemon** exposing *typed operations* over the existing tunnel: `SwitchCamera(mode)`, `GetLinkStats()`, `SetService(name, action)`, `Reboot()` (arm-gated), etc. Transport: gRPC or MQTT (both survive a lossy link and give request/response correlation). The GCS calls the API instead of shelling out.

**What this one change retires:**
- Password + AutoAddPolicy → token / mTLS auth
- Singleton contention → correlation IDs + a queue come for free (A1, B1)
- Reconnect-per-click → one persistent connection (B3)
- Shell interpolation → typed args, no shell (B4, B5)
- Raw "reboot over SSH" → an *authenticated, arm-interlocked* RPC

This is the highest-leverage move. Do it first; everything below gets easier.

---

## Tier 1 — what makes it "industrial"

### 1. Configuration as code (not git-committed /etc backups)
**Current:** live `/etc` rsync'd into a repo and auto-committed. A backup, not config management.
**Consequence:** W1 (companion channel 161 vs relay 157) and W2 (docs say dual-NIC udp_proxy, config ships single-NIC udp_direct_tx) are pure drift bugs.
**Target:** declarative provisioning (Ansible / cloud-init / NixOS). One source of truth **renders** both `wifibroadcast.cfg` files — a channel mismatch becomes structurally impossible — and any node rebuilds bit-identically. Drift stops being a bug class.

### 2. Secrets management
**Current:** no vault; ed25519 key + wfb keys committed to git; sudo password = WPS PIN = `1987`, reused everywhere; PC-side password in keyring.
**Target:** a secrets store (sops/age or systemd-creds), **key-based SSH only**, short-lived **SSH certificates** from a small CA (replaces static keys + AutoAddPolicy), rotation policy, secrets injected at deploy time — never committed. Kills the secret-leak class at the root instead of scrubbing history repeatedly.

### 3. Observability pipeline
**Current:** ad-hoc SSH polling for wifi-temp + reachability; journald siloed on three boxes; no history, no alerting.
**Target:** a metrics agent (node-exporter + a **WFB-NG stats exporter** reading the existing stats ports 8002/8003, API 8102/8103) → time-series DB (Prometheus/InfluxDB); structured logs shipped centrally; heartbeat + alerting.
**Bonus:** this *is* the RSSI/link-quality feedback loop (W5) — delivered as a byproduct — and it replaces the poll storms with a proper agent.

#### 3a. Logging & observability — current state (verified from service configs, 2026-07-08)

**Connectivity (as actually configured, not as diagrammed):**
- **MAVLink:** Pixhawk → `/dev/ttyAMA0@921600` → companion `mavlink-routerd` (TCP:5760 + UDP:14550) → WFB drone → *(RF)* → WFB gs → relay `mavlink-routerd` (in UDP:14560 → out UDP:14550 to QGC 10.5.6.50 + :14551 tracker)
- **ROS2/DDS:** Pixhawk `/dev/ttyAMA4@921600` → `MicroXRCEAgent` → ROS2 Jazzy nodes; `block-traffic.service` drops DDS multicast off RF
- **Video:** cameras → `vision_streaming` (**ROS2 node**, not FFmpeg — doc drift, see C8) → WFB video → relay → QGC UDP:5600 + `mediamtx` RTSP
- **Control/SSH:** relay `autossh -M 0 -L 0.0.0.0:2222:10.5.5.87:22` → companion:22

**Where logs live, per layer:**

| Layer | What logs | Where | Persistent? |
|-------|-----------|-------|-------------|
| GCS (Windows) | QGC app + MAVLink tlogs | QGC folder (`%LOCALAPPDATA%`/Documents\QGroundControl) | Yes (QGC-managed) |
| GCS `pxlabs_cli` | command stdout/stderr | nowhere — transient to QML | **No** |
| Relay services | mavlink-router, autossh(`-v`), mediamtx, dhcpd, sync | journald (no `StandardOutput=`) | **At-risk** |
| Companion services | ROS2 nodes, XRCE agent, mavlink-router, vision, ollama | journald | **At-risk** |
| WFB-NG (both) | link/telemetry stats | journald only; `log_file=None`/`binary_log_file=None`; live stats on 8002/8003 but nothing persists them | **No** |
| Config sync | rsync/git activity | file `logs/system_files_sync.log` | Yes |
| PX4 flight | ulog | Pixhawk SD card (via `px4_mavlink.py ls`) | Yes (on FC) |

**Gaps (the substance behind item #3):**
1. **journald persistence unmanaged** — no `journald.conf` in either backup → distro default `Storage=auto`, which persists only if `/var/log/journal/` exists. If it doesn't, all service logs are RAM-only and **lost on every power-cut**. Biggest gap. Fix: `Storage=persistent` + size caps, verified on hardware.
2. **No onboard MAVLink tlogs** — neither `mavlink-router` config sets a `Log=` dir; companion has `ReportStats=false`. No vehicle-side telemetry record for post-incident analysis.
3. **Broken companion router unit** — malformed `ExecStart` path + missing `-c main.conf` (see `BUG_FIX_companion_relay.md` C6).
4. **Dead logrotate / WFB stats discarded** — rotate rules point at files WFB never writes (see C7). Blocks W5.

**Target logging architecture:** persistent journald (bounded) on every node → structured logs + metrics shipped to a central collector; onboard tlog recording on the companion router; WFB stats exporter (8002/8003) → TSDB; PX4 ulog auto-offload after landing; GCS-side `pxlabs_cli` writes a rotating local log.

---

## Tier 2 — robustness & safety

### 4. Adaptive, self-managing RF link
**Current:** static WFB-NG — fixed channel, fixed MCS1 (~7 Mbps), no adaptation, no failover; video + MAVLink + SSH tunnel share one radio with no guaranteed QoS for safety-critical traffic.
**Target:** adaptive MCS/bitrate driven by RSSI+loss; automatic channel selection with interference blacklist; NIC diversity (mirror); **graceful degradation** — shed video before starving MAVLink/RC. (Ties to W3/W4/W5.)

### 5. Safety / fail-safe architecture
**Current:** right instinct (companion sync script has an arm-check) but ad-hoc; `reboot`/`shutdown` are reachable mid-flight via SSH with a stored password — no arm interlock on the companion side.
**Target:** documented safety case; **all risky remote ops gated on flight state**; command authentication so a replayed/spurious packet can't trigger a reboot; hardware + software watchdogs. Naturally enforced once ops go through the Tier-0 authenticated API.

---

## Tier 3 — engineering discipline

### 6. Reproducible CI/CD + release engineering
**Current:** PX4 fork commits 544 MB of pre-built firmware; QGC built by hand from a CMD window (`build_pxlabs.bat` ends in `pause`); installer built manually.
**Target:** containerized reproducible CI builds; **artifacts in Releases/registry with checksums + provenance** (not git); signed releases; pinned dependencies.

### 7. Automated test + SITL/HIL
**Current:** no SITL or integration tests in the loop.
**Target:** **PX4 SITL in CI** + HIL before flight; a SITL harness to test GCS↔companion integration (and the new control API) without risking hardware.

---

## Suggested sequence
1. **Tier-0 control-plane API** — retires the most bugs, unlocks auth + safety interlocks.
2. **Tier-1 #1 config-as-code + #2 secrets** (coupled) — kills drift and leak classes.
3. **Tier-1 #3 observability** — cheap, high daily value, delivers W5.
4. **Tier-2 #4 adaptive RF + #5 safety** — the airborne-critical work.
5. **Tier-3 #6 CI/CD + #7 SITL/HIL** — sustaining engineering discipline.

Tiers 1–2 are the line between "a well-built research/hobbyist system" and "industrial."

---

## Related docs
- `BUG_FIX.md` — QGC/G-Control tactical bugs (A1 shared-runner, B1–B7)
- `BUG_FIX_companion_relay.md` — WFB-NG (W1–W5) + companion/relay bugs (C1–C5)
- memory `project_repo_audit.md` — public-repo secret leak inventory
