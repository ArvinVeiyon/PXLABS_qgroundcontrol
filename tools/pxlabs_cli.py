#!/usr/bin/env python3
"""
pxlabs_cli.py  —  v2.2
CLI bridge for QGC PXLABS pages and pxlabs_cli integration.

Security fix: sudo password is fed via `printf` instead of `echo`
so it does not appear in `ps aux` on the remote host.

New subcommands vs v2.1 (multi-camera, vision_config_manager v2.0.0):
  companion camera-list [--all]     — camera inventory as JSON (stable id, alias,
                                      formats, role_lock, active primary/secondary)
  companion camera-set-alias --id --name   — store user alias companion-side
  companion camera-apply --primary [--secondary]  — select stream by id/alias
                                      (guarded: depth/IR nodes refused companion-side)

New subcommands vs v2.0:
  config show                       — print resolved config
  companion camera-apply            — apply camera settings via vision_config_manager
  companion camera-query --device   — query camera details via vision_config_manager list-details
  companion camera-params --device --resolution --fps --format  — set resolution/fps/format
"""

import argparse
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

# Force UTF-8 output so Unicode chars from remote (●, …, etc.) don't crash on cp1252 Windows console
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

import keyring
import paramiko

# When frozen by PyInstaller (onefile), __file__ is inside the temp extraction dir.
# Use sys.executable to get the real exe location so config is found next to the exe.
if getattr(sys, "frozen", False):
    ROOT = Path(sys.executable).resolve().parents[1]   # ..\  relative to tools\pxlabs_cli.exe
else:
    ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "config" / "ssh_config.json"

# Full path confirmed in companion repo
WFB_RLYCTL = "/usr/local/sbin/wfb-rlyctl"


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
def _default_config():
    return {
        "primary_ip": "10.5.6.100",
        "primary_port": "2222",
        "secondary_ip": None,
        "secondary_port": "22",
        "username": "roz",
        "relay_ip": "10.5.6.100",
        "relay_ssh_port": "22",
        "relay_username": "vind-admin",
    }


def load_config():
    cfg = _default_config()
    if CONFIG_PATH.exists():
        with CONFIG_PATH.open("r", encoding="utf-8") as f:
            data = json.load(f)
        cfg.update(data)
    return cfg


def get_password(username, env_key):
    pw = os.environ.get(env_key, "")
    if pw:
        return pw
    return keyring.get_password("Drone-Control", username) or ""


# ---------------------------------------------------------------------------
# Network helpers
# ---------------------------------------------------------------------------
def is_reachable(ip, port, timeout=5):
    try:
        socket.create_connection((ip, int(port)), timeout=timeout).close()
        return True
    except Exception:
        return False


def pick_companion_host(cfg):
    primary_ip   = cfg.get("primary_ip")
    primary_port = cfg.get("primary_port", "22")
    secondary_ip   = cfg.get("secondary_ip")
    secondary_port = cfg.get("secondary_port", "22")

    if primary_ip and is_reachable(primary_ip, primary_port):
        return primary_ip, primary_port
    if secondary_ip and is_reachable(secondary_ip, secondary_port):
        return secondary_ip, secondary_port
    return primary_ip, primary_port


# ---------------------------------------------------------------------------
# SSH helpers
# ---------------------------------------------------------------------------
def _sudo_wrap(command: str, password: str) -> str:
    """Feed sudo password via printf (not echo) to avoid ps exposure."""
    if command.startswith("sudo "):
        pw = password.replace("'", "'\"'\"'")
        return f"printf '%s\\n' '{pw}' | sudo -S {command[5:]}"
    return command


def ssh_exec(host, port, username, password, command):
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        ssh.connect(host, int(port), username, password, timeout=10)
        cmd = _sudo_wrap(command, password)
        stdin, stdout, stderr = ssh.exec_command(cmd)
        exit_status = stdout.channel.recv_exit_status()
        out = stdout.read().decode(errors="ignore")
        err = stderr.read().decode(errors="ignore")
        return exit_status == 0, out, err, exit_status
    except Exception as e:
        return False, "", f"SSH error: {e}", 1
    finally:
        try:
            ssh.close()
        except Exception:
            pass


def sftp_get(host, port, username, password, remote_path, local_path):
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        ssh.connect(host, int(port), username, password, timeout=10)
        sftp = ssh.open_sftp()
        sftp.get(remote_path, local_path)
        sftp.close()
        return True
    except Exception as e:
        print(f"ERROR: file transfer failed: {e}", file=sys.stderr)
        return False
    finally:
        try:
            ssh.close()
        except Exception:
            pass


def sftp_put_text(host, port, username, password, text, remote_path):
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        ssh.connect(host, int(port), username, password, timeout=10)
        sftp = ssh.open_sftp()
        with sftp.open(remote_path, "w") as f:
            f.write(text)
        sftp.close()
        return True
    except Exception as e:
        print(f"ERROR: upload failed: {e}", file=sys.stderr)
        return False
    finally:
        try:
            ssh.close()
        except Exception:
            pass


def run_cmd(ok, out, err, exit_status):
    if out:
        print(out.strip(), flush=True)
    if err:
        print(err.strip(), file=sys.stderr, flush=True)
    return 0 if ok else (exit_status if exit_status is not None else 1)


# ---------------------------------------------------------------------------
# WFB config editing (wifibroadcast.cfg on companion/relay)
# ---------------------------------------------------------------------------
WFB_CFG_PATH     = "/etc/wifibroadcast.cfg"
WFB_CFG_DEFAULT  = "/etc/wifibroadcast.cfg.default"
WFB_CFG_APPLY    = "/usr/local/sbin/wfb-cfg-apply"
WFB_CFG_CONFIRM  = "/run/wfb-cfg-confirm"

# TIER1: safe to change one side; monitor-mode RX adapts (TX announces per session/packet).
# TIER2: MUST match both ends — mismatch permanently kills the link. Gated.
WFB_TIER1 = {
    "common.wifi_txpower": (100, 3000),
    "base.mcs_index":      (0, 7),
    "base.stbc":           (0, 1),
    "base.ldpc":           (0, 1),
    "video.fec_k":         (1, 12),
    "video.fec_n":         (2, 16),
    "mavlink.fec_k":       (1, 12),
    "mavlink.fec_n":       (2, 16),
    "tunnel.fec_k":        (1, 12),
    "tunnel.fec_n":        (2, 16),
}
WFB_TIER2 = {
    "common.wifi_channel": (1, 177),
    "base.bandwidth":      (20, 40),
}
WFB_ALL_PARAMS = {**WFB_TIER1, **WFB_TIER2}


def _wfb_target_conn(target, cfg):
    """(host, port, username, password) for companion or relay."""
    if target == "relay":
        user = cfg.get("relay_username", "vind-admin")
        return (cfg.get("relay_ip"), cfg.get("relay_ssh_port", "22"),
                user, get_password(user, "PXLABS_RELAY_PASSWORD"))
    ip, port = pick_companion_host(cfg)
    user = cfg.get("username", "roz")
    return ip, port, user, get_password(user, "PXLABS_COMPANION_PASSWORD")


def _wfb_parse_params(spec):
    """'base.mcs_index=2,video.fec_k=8' -> {(section, key): int_value}; validates."""
    out = {}
    for part in (spec or "").split(","):
        part = part.strip()
        if not part:
            continue
        if "=" not in part or "." not in part.split("=", 1)[0]:
            raise ValueError(f"bad param '{part}' (expected section.key=value)")
        name, val = part.split("=", 1)
        name = name.strip()
        if name not in WFB_ALL_PARAMS:
            raise ValueError(f"unknown/blocked param '{name}' "
                             f"(allowed: {', '.join(sorted(WFB_ALL_PARAMS))})")
        try:
            ival = int(val.strip())
        except ValueError:
            raise ValueError(f"{name}: value must be an integer")
        lo, hi = WFB_ALL_PARAMS[name]
        if not lo <= ival <= hi:
            raise ValueError(f"{name}: {ival} out of range [{lo}..{hi}]")
        if name == "base.bandwidth" and ival not in (20, 40):
            raise ValueError("base.bandwidth must be 20 or 40")
        section, key = name.split(".", 1)
        out[(section, key)] = ival
    if not out:
        raise ValueError("no parameters given")
    # cross-check FEC sanity: n > k whenever both are set
    for stream in ("video", "mavlink", "tunnel"):
        k = out.get((stream, "fec_k"))
        n = out.get((stream, "fec_n"))
        if k is not None and n is not None and n <= k:
            raise ValueError(f"{stream}: fec_n ({n}) must be > fec_k ({k})")
    return out


def _wfb_cfg_edit(text, edits):
    """Apply {(section,key): value} edits to cfg text; error if a key is missing."""
    lines = text.splitlines()
    cur = None
    pending = dict(edits)
    for i, line in enumerate(lines):
        m = re.match(r"\s*\[(\w+)\]", line)
        if m:
            cur = m.group(1)
            continue
        for (section, key), val in list(pending.items()):
            if cur == section and re.match(rf"\s*{re.escape(key)}\s*=", line):
                cm = re.search(r"(#.*)$", line)
                comment = f"  {cm.group(1)}" if cm else ""
                lines[i] = f"{key} = {val}{comment}"
                del pending[(section, key)]
    if pending:
        missing = ", ".join(f"{s}.{k}" for s, k in pending)
        raise ValueError(f"keys not found in remote cfg: {missing}")
    return "\n".join(lines) + "\n"


def _wfb_extract_params(text):
    """Print current values of all tunable params as section.key=value lines."""
    vals = {}
    cur = None
    for line in text.splitlines():
        m = re.match(r"\s*\[(\w+)\]", line)
        if m:
            cur = m.group(1)
            continue
        m = re.match(r"\s*(\w+)\s*=\s*([^#]+)", line)
        if m and cur:
            name = f"{cur}.{m.group(1)}"
            if name in WFB_ALL_PARAMS:
                vals[name] = m.group(2).strip()
    return vals


def _wfb_secondary_ok(cfg):
    sec_ip = cfg.get("secondary_ip")
    sec_port = cfg.get("secondary_port", "22")
    return bool(sec_ip) and is_reachable(sec_ip, sec_port, timeout=4)


def _wfb_confirm_loop(routes, user, pw, deadline):
    """Poll (host, port) routes until one accepts an SSH confirm touch, or the
    deadline passes. Returns True once the watchdog confirm file is touched."""
    while time.time() < deadline:
        time.sleep(3)
        for host, port in routes:
            if not is_reachable(host, port, timeout=3):
                continue
            ok, _o, _e, _s = ssh_exec(host, port, user, pw,
                                      f"sudo touch {WFB_CFG_CONFIRM}")
            if ok:
                return True
    return False


def _wfb_set_both(args, cfg):
    """Apply the same params to companion FIRST, then relay. Neither end is
    confirmed until both applied — on any failure no confirm is sent and both
    watchdogs roll back, so the two configs always end up matching.
    common.wifi_txpower is per-side by fleet convention and is rejected here."""
    timeout      = int(args.timeout or 60)   # relay watchdog + confirm window
    comp_timeout = timeout * 2 + 60          # companion must outlive the relay phase

    try:
        edits = _wfb_parse_params(args.params)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    if ("common", "wifi_txpower") in edits:
        print("ERROR: common.wifi_txpower is per-side (drone thermal vs ground amp) — "
              "use 'set --target', not set-both", file=sys.stderr)
        return 1
    danger = [f"{s}.{k}" for (s, k) in edits if f"{s}.{k}" in WFB_TIER2]
    if danger:
        if not args.danger_ack:
            print(f"ERROR: {', '.join(danger)} affects BOTH ends — "
                  f"requires --danger-ack", file=sys.stderr)
            return 1
        if not _wfb_secondary_ok(cfg):
            print("ERROR: secondary connection to companion not reachable — "
                  "refusing dangerous change (channel/bandwidth) without a "
                  "recovery path", file=sys.stderr)
            return 1

    conns = {"companion": _wfb_target_conn("companion", cfg),
             "relay":     _wfb_target_conn("relay", cfg)}

    # Read + edit BOTH cfgs up front so a missing key or unreachable side
    # aborts before anything is touched.
    new_texts, orig_texts = {}, {}
    for name in ("companion", "relay"):
        host, port, user, pw = conns[name]
        ok, out, err, st = ssh_exec(host, port, user, pw, f"cat {WFB_CFG_PATH}")
        if not ok:
            print(f"ERROR: cannot read {name} cfg: {err.strip()}", file=sys.stderr)
            return 1
        try:
            new_texts[name] = _wfb_cfg_edit(out, edits)
        except ValueError as e:
            print(f"ERROR ({name}): {e}", file=sys.stderr)
            return 1
        orig_texts[name] = out

    def push_apply(name, text, tmo):
        host, port, user, pw = conns[name]
        if not sftp_put_text(host, port, user, pw, text, "/tmp/wfb-new.cfg"):
            return False
        ok, out, err, st = ssh_exec(host, port, user, pw,
                                    f"sudo {WFB_CFG_APPLY} /tmp/wfb-new.cfg {tmo}")
        print(out.strip(), flush=True)
        if not ok:
            print(err.strip(), file=sys.stderr, flush=True)
        return ok

    # Companion confirm routes: primary, plus secondary if configured (during a
    # channel change the primary only returns after the relay side flips too).
    chost, cport, cuser, cpw = conns["companion"]
    comp_routes = [(chost, cport)]
    sec_ip = cfg.get("secondary_ip")
    if sec_ip:
        comp_routes.append((sec_ip, cfg.get("secondary_port", "22")))

    print(f"[1/4] applying to companion (watchdog {comp_timeout}s, unconfirmed)…",
          flush=True)
    if not push_apply("companion", new_texts["companion"], comp_timeout):
        print("ABORTED: companion apply failed — relay untouched, companion "
              "watchdog restores its previous config", flush=True)
        return 1

    print(f"[2/4] applying to relay (watchdog {timeout}s)…", flush=True)
    if not push_apply("relay", new_texts["relay"], timeout):
        print("ROLLED_BACK: relay apply failed — companion left unconfirmed; its "
              f"watchdog restores the previous config within {comp_timeout}s, "
              "ends stay matched", flush=True)
        return 1

    print("[3/4] waiting for companion, then confirming…", flush=True)
    if not _wfb_confirm_loop(comp_routes, cuser, cpw,
                             time.time() + max(timeout - 15, 15)):
        print("ROLLED_BACK: companion unreachable — neither end confirmed; both "
              "watchdogs restore the previous configs", flush=True)
        return 1

    print("[4/4] confirming relay…", flush=True)
    rhost, rport, ruser, rpw = conns["relay"]
    ok, _o, _e, _s = ssh_exec(rhost, rport, ruser, rpw,
                              f"sudo touch {WFB_CFG_CONFIRM}")
    if ok:
        print("APPLIED_BOTH (companion + relay confirmed — new config kept)",
              flush=True)
        return 0

    # Companion kept the new cfg but the relay will roll back — revert the
    # companion so the ends match again.
    print("relay confirm failed (relay rolls back) — reverting companion to the "
          "previous config…", file=sys.stderr, flush=True)
    if push_apply("companion", orig_texts["companion"], timeout) and \
       _wfb_confirm_loop(comp_routes, cuser, cpw,
                         time.time() + max(timeout - 15, 15)):
        print("REVERTED: both ends back on the previous config", flush=True)
        return 1
    print("MISMATCH_DANGER: relay rolled back but companion may still run the new "
          "config — verify both wifibroadcast.cfg manually!",
          file=sys.stderr, flush=True)
    return 1


def wfb_config_actions(args, cfg):
    action = args.action

    if action == "check-secondary":
        ok = _wfb_secondary_ok(cfg)
        print(f"SECONDARY:{'reachable' if ok else 'unreachable'}", flush=True)
        return 0 if ok else 1

    if action == "set-both":
        return _wfb_set_both(args, cfg)

    target = args.target
    if target not in ("companion", "relay"):
        print("ERROR: --target companion|relay required", file=sys.stderr)
        return 1
    host, port, user, pw = _wfb_target_conn(target, cfg)

    if action == "get":
        ok, out, err, st = ssh_exec(host, port, user, pw, f"cat {WFB_CFG_PATH}")
        return run_cmd(ok, out, err, st)

    if action == "params":
        ok, out, err, st = ssh_exec(host, port, user, pw, f"cat {WFB_CFG_PATH}")
        if not ok:
            return run_cmd(ok, out, err, st)
        for name, val in sorted(_wfb_extract_params(out).items()):
            tier = "TIER2" if name in WFB_TIER2 else "TIER1"
            print(f"{name}={val} [{tier}]", flush=True)
        return 0

    if action == "confirm":
        ok, out, err, st = ssh_exec(host, port, user, pw,
                                    f"sudo touch {WFB_CFG_CONFIRM}")
        print("CONFIRMED" if ok else "CONFIRM_FAILED", flush=True)
        return 0 if ok else 1

    if action in ("set", "restore-default"):
        timeout = int(args.timeout or 60)

        if action == "set":
            try:
                edits = _wfb_parse_params(args.params)
            except ValueError as e:
                print(f"ERROR: {e}", file=sys.stderr)
                return 1
            danger = [f"{s}.{k}" for (s, k) in edits
                      if f"{s}.{k}" in WFB_TIER2]
            if danger:
                if not args.danger_ack:
                    print(f"ERROR: {', '.join(danger)} affects BOTH ends — "
                          f"requires --danger-ack", file=sys.stderr)
                    return 1
                if target == "companion" and not _wfb_secondary_ok(cfg):
                    print("ERROR: secondary connection to companion not reachable — "
                          "refusing dangerous change (channel/bandwidth) without a "
                          "recovery path", file=sys.stderr)
                    return 1
            ok, out, err, st = ssh_exec(host, port, user, pw, f"cat {WFB_CFG_PATH}")
            if not ok:
                return run_cmd(ok, out, err, st)
            try:
                new_text = _wfb_cfg_edit(out, edits)
            except ValueError as e:
                print(f"ERROR: {e}", file=sys.stderr)
                return 1
            if not sftp_put_text(host, port, user, pw, new_text, "/tmp/wfb-new.cfg"):
                return 1
            src = "/tmp/wfb-new.cfg"
        else:
            src = WFB_CFG_DEFAULT

        ok, out, err, st = ssh_exec(
            host, port, user, pw,
            f"sudo {WFB_CFG_APPLY} {src} {timeout}")
        if not ok:
            print(out.strip(), flush=True)
            print(err.strip(), file=sys.stderr, flush=True)
            return 1
        print(out.strip(), flush=True)

        # Poll until the device is reachable again, then send confirm so the
        # watchdog keeps the new cfg. If it never comes back, the device
        # rolls itself back at the timeout.
        deadline = time.time() + max(timeout - 8, 10)
        while time.time() < deadline:
            time.sleep(3)
            if not is_reachable(host, port, timeout=3):
                continue
            ok2, _o, _e, _s = ssh_exec(host, port, user, pw,
                                       f"sudo touch {WFB_CFG_CONFIRM}")
            if ok2:
                print("APPLIED (confirmed — new config kept)", flush=True)
                return 0
        print("ROLLED_BACK (device unreachable — watchdog restores previous config)",
              flush=True)
        return 1

    print(f"ERROR: unknown wfb-config action '{action}'", file=sys.stderr)
    return 1


# ---------------------------------------------------------------------------
# Camera device mapping
# ---------------------------------------------------------------------------
def companion_camera_device(swap, front=True):
    if swap:
        return "/dev/video2" if front else "/dev/video0"
    return "/dev/video0" if front else "/dev/video2"


# ---------------------------------------------------------------------------
# companion subcommand
# ---------------------------------------------------------------------------
def companion_actions(args, cfg):
    ip, port = pick_companion_host(cfg)
    username = cfg.get("username", "roz")
    action   = args.action

    # SSH terminal and wifi-temp don't require stored password (use SSH key / attempt)
    if action == "ssh-terminal":
        print(f"Opening SSH terminal: ssh -p {port} {username}@{ip}", flush=True)
        if sys.platform.startswith("win"):
            # StrictHostKeyChecking=no: port 2222 presents the companion host key
            # which differs from relay:22 and may not be in Windows known_hosts
            subprocess.Popen(["cmd.exe", "/c",
                              f'start cmd /k ssh -o StrictHostKeyChecking=no -p {port} {username}@{ip}'],
                             shell=False)
        else:
            subprocess.Popen(["/bin/sh", "-lc",
                              f"gnome-terminal -- ssh -o StrictHostKeyChecking=no -p {port} {username}@{ip}"])
        return 0

    password = get_password(username, "PXLABS_COMPANION_PASSWORD") or ""

    if action == "wifi-temp":
        if not password:
            print("N/A", flush=True)
            return 0
        # falls through to wifi-temp handler below

    if action not in ("wifi-temp",) and not password:
        print("ERROR: companion password not found (keyring or PXLABS_COMPANION_PASSWORD env)", file=sys.stderr)
        return 1

    swap = getattr(args, "swap", False)

    if action == "front-switch":
        device = companion_camera_device(swap, front=True)
        return run_cmd(*ssh_exec(ip, port, username, password, f"sudo vision_config_manager {device}"))

    if action == "bottom-switch":
        device = companion_camera_device(swap, front=False)
        return run_cmd(*ssh_exec(ip, port, username, password, f"sudo vision_config_manager {device}"))

    if action == "split-front-bottom":
        d1, d2 = ("/dev/video2", "/dev/video0") if swap else ("/dev/video0", "/dev/video2")
        return run_cmd(*ssh_exec(ip, port, username, password, f"sudo vision_config_manager {d1} {d2}"))

    if action == "split-bottom-front":
        d1, d2 = ("/dev/video0", "/dev/video2") if swap else ("/dev/video2", "/dev/video0")
        return run_cmd(*ssh_exec(ip, port, username, password, f"sudo vision_config_manager {d1} {d2}"))

    if action == "wifi-temp":
        clamp_min, clamp_max = -40.0, 130.0
        try:
            ssh = paramiko.SSHClient()
            ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            ssh.connect(ip, int(port), username, password, timeout=10)

            def _read(cmd):
                _, stdout, _ = ssh.exec_command(cmd)
                stdout.channel.settimeout(10)
                return stdout.read().decode(errors="ignore").strip()

            # Detect WFB interface: 1) wifibroadcast config, 2) procfs
            iface = _read(r"""sh -lc '
if [ -r /etc/default/wifibroadcast ]; then
  v=$(grep -E "^[[:space:]]*WFB_NICS=" /etc/default/wifibroadcast | tail -n1 | cut -d= -f2-)
  v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}; set -- $v; echo "${1:-}"
fi'""")
            if not iface:
                iface = _read(r"sh -lc 'ls -1 /proc/net/rtl88x2eu 2>/dev/null | grep -E ^wl | head -n1 || true'")

            # A) procfs thermal_state
            if iface:
                out = _read(f"sh -lc 'timeout 2s cat /proc/net/rtl88x2eu/{iface}/thermal_state 2>/dev/null || true'")
                temps = [float(m.group(1)) for m in re.finditer(r"temperature:\s*(-?\d+(?:\.\d+)?)", out)
                         if clamp_min <= float(m.group(1)) <= clamp_max]
                if temps:
                    print(f"{max(temps):.1f}", flush=True)
                    ssh.close()
                    return 0

            # B) wfb-cli drone
            out = _read(r"""sh -lc '
TO=2
out=$((timeout ${TO}s /usr/local/sbin/wfb-cli drone || timeout ${TO}s /usr/local/bin/wfb-cli drone || timeout ${TO}s wfb-cli drone) 2>/dev/null)
echo "$out" | grep -iE "temp|temperature" | head -n 20 || true'""")
            m = re.search(r"(-?\d+(?:\.\d+)?)\s*°?\s*[Cc]\b", out)
            if m:
                val = float(m.group(1))
                if clamp_min <= val <= clamp_max:
                    print(f"{val:.1f}", flush=True)
                    ssh.close()
                    return 0

            # C) sysfs hwmon
            out = _read(r"""sh -lc '
for p in /sys/class/ieee80211/*/device/hwmon/*/temp1_input /sys/class/hwmon/hwmon*/temp1_input; do
  [ -r "$p" ] || continue
  v=$(timeout 2s cat "$p" 2>/dev/null) || continue
  echo "$v"; break
done'""")
            if out:
                try:
                    v = float(out)
                    if v > 200:
                        v /= 1000.0
                    if clamp_min <= v <= clamp_max:
                        print(f"{v:.1f}", flush=True)
                        ssh.close()
                        return 0
                except Exception:
                    pass

            print("N/A", flush=True)
            ssh.close()
            return 0
        except Exception as e:
            print(f"N/A", flush=True)
            print(f"wifi-temp error: {e}", file=sys.stderr, flush=True)
            return 0

    if action == "camera-list":
        # Machine-readable inventory: stable ids, aliases, formats, role_lock,
        # active primary/secondary. Stdout carries only the JSON object.
        flag = " --all" if getattr(args, "all", False) else ""
        return run_cmd(*ssh_exec(ip, port, username, password,
                                  f"sudo vision_config_manager list --json{flag}"))

    if action == "camera-set-alias":
        cam_id = getattr(args, "id", "") or ""
        name   = (getattr(args, "name", "") or "").strip()
        if not cam_id or not name:
            print("ERROR: camera-set-alias requires --id and --name", file=sys.stderr)
            return 1
        return run_cmd(*ssh_exec(ip, port, username, password,
                                  f"sudo vision_config_manager set-alias "
                                  f"{shlex.quote(cam_id)} {shlex.quote(name)} 2>&1"))

    if action == "camera-apply":
        primary   = getattr(args, "primary", "") or ""
        secondary = getattr(args, "secondary", "") or ""
        if primary:
            # v2 path: id/alias/dev resolved companion-side, guarded against
            # non-streamable (depth/IR) devices. Guard message lands on stdout.
            cmd = f"sudo vision_config_manager apply {shlex.quote(primary)}"
            if secondary:
                cmd += f" {shlex.quote(secondary)}"
            return run_cmd(*ssh_exec(ip, port, username, password, cmd + " 2>&1"))
        # Legacy path (--device): positional mode, same resolve+guard since v2
        device = getattr(args, "device", "/dev/video0")
        return run_cmd(*ssh_exec(ip, port, username, password, f"sudo vision_config_manager {device}"))

    if action == "camera-query":
        device = getattr(args, "device", "/dev/video0")
        return run_cmd(*ssh_exec(ip, port, username, password,
                                  f"sudo vision_config_manager list-details {device} 2>&1"))

    if action == "camera-params":
        device     = getattr(args, "device",     "/dev/video0")
        resolution = getattr(args, "resolution", "1920x1080")
        fps        = getattr(args, "fps",        "60")
        fmt        = getattr(args, "format",     "MJPG")
        return run_cmd(*ssh_exec(ip, port, username, password,
                                  f"sudo vision_config_manager set-cam-params {device} {resolution} {fps} --format {fmt} 2>&1"))

    if action in ("capture-front", "capture-bottom"):
        front = action == "capture-front"
        device = companion_camera_device(swap, front=front)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        remote_path = f"/home/{username}/Model_image/Rozcam_{timestamp}.jpg"
        local_path = Path.home() / "Pictures" / f"Rozcam_{timestamp}.jpg"
        local_path.parent.mkdir(parents=True, exist_ok=True)
        ok, out, err, code = ssh_exec(ip, port, username, password, f"Rozcam -i {device}")
        if not ok:
            return run_cmd(ok, out, err, code)
        time.sleep(2)
        if sftp_get(ip, port, username, password, remote_path, str(local_path)):
            print(f"Saved: {local_path}")
            return 0
        return 1

    if action == "reboot":
        # systemd-run schedules via transient timer, detached from SSH session
        # so recv_exit_status() returns before the connection is killed
        return run_cmd(*ssh_exec(ip, port, username, password,
                                 "sudo systemd-run --on-active=0 systemctl reboot"))

    if action == "shutdown":
        return run_cmd(*ssh_exec(ip, port, username, password,
                                 "sudo systemd-run --on-active=0 systemctl poweroff"))

    print("ERROR: unknown companion action", file=sys.stderr)
    return 1


# ---------------------------------------------------------------------------
# relay subcommand
# ---------------------------------------------------------------------------
def relay_actions(args, cfg):
    ip       = cfg.get("relay_ip", "")
    port     = cfg.get("relay_ssh_port", "22")
    username = cfg.get("relay_username", "vind-admin")
    action   = args.action

    # SSH terminal needs no stored password — open an interactive window
    if action == "ssh-terminal":
        print(f"Opening SSH terminal: ssh -p {port} {username}@{ip}", flush=True)
        if sys.platform.startswith("win"):
            subprocess.Popen(["cmd.exe", "/c", f'start cmd /k ssh -p {port} {username}@{ip}'],
                             shell=False)
        else:
            subprocess.Popen(["/bin/sh", "-lc", f"gnome-terminal -- ssh -p {port} {username}@{ip}"])
        return 0

    password = get_password(username, "PXLABS_RELAY_PASSWORD")
    if not password:
        print("ERROR: relay password not found (keyring or PXLABS_RELAY_PASSWORD env)", file=sys.stderr)
        return 1

    if action == "reboot":
        return run_cmd(*ssh_exec(ip, port, username, password,
                                 "sudo systemd-run --on-active=0 systemctl reboot"))
    if action == "shutdown":
        return run_cmd(*ssh_exec(ip, port, username, password,
                                 "sudo systemd-run --on-active=0 systemctl poweroff"))

    if action == "wfb":
        wfb = args.wfb_action
        if wfb == "refresh":
            cmd = (
                "bash -lc '"
                f"sa=$(systemctl is-active wifibroadcast@gs.service 2>/dev/null || echo unknown); "
                f"ca=$(systemctl is-active wifibroadcast-cluster@gs.service 2>/dev/null || echo unknown); "
                f"n=$({WFB_RLYCTL} get-nics 2>/dev/null || true); "
                f'echo "SA:$sa"; echo "CA:$ca"; echo "NICS:$n"\''
            )
            return run_cmd(*ssh_exec(ip, port, username, password, cmd))
        if wfb == "switch":
            if args.mode not in ("standalone", "cluster"):
                print("ERROR: --mode standalone|cluster", file=sys.stderr)
                return 1
            cmd = (f"sudo {WFB_RLYCTL} use-standalone" if args.mode == "standalone"
                   else f"sudo {WFB_RLYCTL} use-cluster")
            return run_cmd(*ssh_exec(ip, port, username, password, cmd))
        if wfb == "status":
            return run_cmd(*ssh_exec(ip, port, username, password, f"{WFB_RLYCTL} status"))
        if wfb == "logs":
            cmd = (
                'sh -lc "echo \\"### wifibroadcast@gs.service\\"; '
                'journalctl -u wifibroadcast@gs.service -n 120 --no-pager 2>&1; echo; '
                'echo \\"### wifibroadcast-cluster@gs.service\\"; '
                'journalctl -u wifibroadcast-cluster@gs.service -n 120 --no-pager 2>&1"'
            )
            return run_cmd(*ssh_exec(ip, port, username, password, cmd))
        if wfb == "view-config":
            cmd = r'''bash -lc "
printf '%s\n' '### /etc/default/wifibroadcast';
(sudo -n cat /etc/default/wifibroadcast 2>/dev/null || cat /etc/default/wifibroadcast 2>/dev/null || echo '(missing or no permission)');
echo;
printf '%s\n' '### /etc/wifibroadcast.cfg';
(sudo -n cat /etc/wifibroadcast.cfg 2>/dev/null || cat /etc/wifibroadcast.cfg 2>/dev/null || echo '(missing or no permission)');
echo;
printf '%s\n' '### /etc/wifibroadcast.cfg ([cluster])';
if [ -f /etc/wifibroadcast.cfg ]; then
  sed -n '/^\[cluster\]/{:a;p;n;/^\[/{q};ba}' /etc/wifibroadcast.cfg 2>/dev/null || echo '(parse error)';
else
  echo '(missing)';
fi
"'''
            return run_cmd(*ssh_exec(ip, port, username, password, cmd))
        if wfb == "list-nics":
            return run_cmd(*ssh_exec(ip, port, username, password, f"{WFB_RLYCTL} list-nics"))
        if wfb == "set-nics":
            if not args.nics:
                print("ERROR: --nics required", file=sys.stderr)
                return 1
            return run_cmd(*ssh_exec(ip, port, username, password,
                                      f"sudo {WFB_RLYCTL} set-nics {args.nics}"))

    print("ERROR: unknown relay action", file=sys.stderr)
    return 1


# ---------------------------------------------------------------------------
# services subcommand
# ---------------------------------------------------------------------------
COMPANION_SERVICES = [
    "avahi-daemon.service",
    "cron.service",
    "dbus.service",
    "mavlink.router.service",
    "microxrce-agent.service",
    "polkit.service",
    "rc_control_node.service",
    "ros2_external_node_reg.service",
    "ros2_px4_translation_node.service",
    "rsyslog.service",
    "ssh.service",
    "systemd-journald.service",
    "systemd-logind.service",
    "systemd-resolved.service",
    "systemd-timesyncd.service",
    "systemd-udevd.service",
    "tfmini.service",
    "vision_streaming.service",
    "wifibroadcast@drone.service",
]

RELAY_SERVICES = [
    "avahi-daemon.service",
    "cron.service",
    "dbus.service",
    "isc-dhcp-server.service",
    "isc-dhcp-server6.service",
    "mavlink.router.service",
    "mediamtx.service",
    "polkit.service",
    "relay_files_sync.timer",
    "rsyslog.service",
    "ssh.service",
    "ssh-tunnel-to-companion.service",
    "systemd-journald.service",
    "systemd-logind.service",
    "systemd-resolved.service",
    "systemd-timesyncd.service",
    "systemd-udevd.service",
    "wfb-cluster.service",
    "wifibroadcast.service",
    "wifibroadcast@gs.service",
]


def services_actions(args, cfg):
    target = args.target
    default_services = RELAY_SERVICES if target == "relay" else COMPANION_SERVICES
    services = cfg.get("important_services") or default_services

    if target == "companion":
        ip, port = pick_companion_host(cfg)
        username = cfg.get("username", "roz")
        password = get_password(username, "PXLABS_COMPANION_PASSWORD")
    else:
        ip       = cfg.get("relay_ip", "")
        port     = cfg.get("relay_ssh_port", "22")
        username = cfg.get("relay_username", "vind-admin")
        password = get_password(username, "PXLABS_RELAY_PASSWORD")

    if not password:
        print("ERROR: password not found for target", file=sys.stderr)
        return 1

    if args.action == "refresh":
        svc_list = " ".join(f'"{s}"' for s in services)
        cmd = (
            f"bash -lc 'for s in {svc_list}; do "
            f'a=$(systemctl is-active "$s" 2>/dev/null); a=${{a:-unknown}}; '
            f'e=$(systemctl is-enabled "$s" 2>/dev/null); e=${{e:-unknown}}; '
            f'echo "$s|$a|$e"; done\''
        )
        return run_cmd(*ssh_exec(ip, port, username, password, cmd))

    if args.action in ("start", "stop", "restart", "enable", "disable"):
        if not args.service:
            print("ERROR: --service required", file=sys.stderr)
            return 1
        if args.action == "enable":
            cmd = f"sudo systemctl enable --now {args.service}"
        elif args.action == "disable":
            cmd = f"sudo systemctl disable --now {args.service}"
        else:
            cmd = f"sudo systemctl {args.action} {args.service}"
        return run_cmd(*ssh_exec(ip, port, username, password, cmd))

    print("ERROR: unknown services action", file=sys.stderr)
    return 1


# ---------------------------------------------------------------------------
# config subcommand
# ---------------------------------------------------------------------------
def config_actions(args, cfg):
    if args.action == "show":
        safe = {k: ("***" if "password" in k.lower() else v) for k, v in cfg.items()}
        print(json.dumps(safe, indent=2))
        print(f"\nConfig file: {CONFIG_PATH}")
        return 0

    if args.action == "set":
        # Update non-password fields in ssh_config.json
        updates = {}
        if getattr(args, "primary_ip",      None) is not None: updates["primary_ip"]      = args.primary_ip
        if getattr(args, "primary_port",    None) is not None: updates["primary_port"]     = args.primary_port
        if getattr(args, "secondary_ip",    None) is not None: updates["secondary_ip"]     = args.secondary_ip
        if getattr(args, "secondary_port",  None) is not None: updates["secondary_port"]   = args.secondary_port
        if getattr(args, "username",        None) is not None: updates["username"]         = args.username
        if getattr(args, "relay_ip",        None) is not None: updates["relay_ip"]         = args.relay_ip
        if getattr(args, "relay_ssh_port",  None) is not None: updates["relay_ssh_port"]   = args.relay_ssh_port
        if getattr(args, "relay_username",  None) is not None: updates["relay_username"]   = args.relay_username

        cfg.update(updates)
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with CONFIG_PATH.open("w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)
        print(f"Config saved: {CONFIG_PATH}")

        # Save passwords to keyring
        comp_user  = cfg.get("username",       "roz")
        relay_user = cfg.get("relay_username", "vind-admin")
        if getattr(args, "companion_password", None) is not None and args.companion_password:
            keyring.set_password("Drone-Control", comp_user, args.companion_password)
            print(f"Companion password saved to keyring (user: {comp_user})")
        if getattr(args, "relay_password", None) is not None and args.relay_password:
            keyring.set_password("Drone-Control", relay_user, args.relay_password)
            print(f"Relay password saved to keyring (user: {relay_user})")
        return 0

    print("ERROR: unknown config action", file=sys.stderr)
    return 1


# ---------------------------------------------------------------------------
# status subcommand — fast TCP reachability check, no password needed
# ---------------------------------------------------------------------------
def status_actions(cfg):
    primary_ip     = cfg.get("primary_ip", "")
    primary_port   = cfg.get("primary_port", "22")
    secondary_ip   = cfg.get("secondary_ip")
    secondary_port = cfg.get("secondary_port", "22")
    relay_ip       = cfg.get("relay_ip", "")
    relay_port     = cfg.get("relay_ssh_port", "22")

    # Companion: try primary, fall back to secondary
    comp_ok = bool(primary_ip and is_reachable(primary_ip, primary_port, timeout=3))
    if not comp_ok and secondary_ip:
        comp_ok = is_reachable(secondary_ip, secondary_port, timeout=3)

    # Relay
    relay_ok = bool(relay_ip and is_reachable(relay_ip, relay_port, timeout=3))

    print(f"COMPANION:{'reachable' if comp_ok else 'unreachable'}", flush=True)
    print(f"RELAY:{'reachable' if relay_ok else 'unreachable'}", flush=True)
    return 0


# ---------------------------------------------------------------------------
# CLI parser
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="PXLABS CLI v2.2 — companion/relay control bridge")
    sub = parser.add_subparsers(dest="cmd", required=True)

    # companion
    p_comp = sub.add_parser("companion")
    p_comp.add_argument("action", choices=[
        "front-switch", "bottom-switch", "split-front-bottom", "split-bottom-front",
        "camera-list", "camera-set-alias",
        "camera-apply", "camera-query", "camera-params",
        "wifi-temp",
        "capture-front", "capture-bottom",
        "reboot", "shutdown", "ssh-terminal",
    ])
    p_comp.add_argument("--swap",       action="store_true", help="swap camera mapping")
    p_comp.add_argument("--device",     default="/dev/video0", help="camera device path (or stable id/alias)")
    p_comp.add_argument("--resolution", default="1920x1080",   help="resolution e.g. 1920x1080")
    p_comp.add_argument("--fps",        default="60",          help="frames per second")
    p_comp.add_argument("--format",     default="MJPG",        help="pixel format e.g. MJPG or UYVY")
    p_comp.add_argument("--all",        action="store_true",   help="camera-list: include non-streamable nodes")
    p_comp.add_argument("--id",         default="",            help="camera-set-alias: stable camera id")
    p_comp.add_argument("--name",       default="",            help="camera-set-alias: alias (1-32 chars)")
    p_comp.add_argument("--primary",    default="",            help="camera-apply: primary camera id/alias/dev")
    p_comp.add_argument("--secondary",  default="",            help="camera-apply: secondary PiP camera id/alias/dev")

    # relay
    p_relay = sub.add_parser("relay")
    p_relay.add_argument("action", choices=["reboot", "shutdown", "ssh-terminal", "wfb"])
    p_relay.add_argument("wfb_action", nargs="?",
                         choices=["refresh", "switch", "status", "logs",
                                  "view-config", "list-nics", "set-nics"])
    p_relay.add_argument("--mode",  choices=["standalone", "cluster"])
    p_relay.add_argument("--nics")

    # services
    p_svc = sub.add_parser("services")
    p_svc.add_argument("action", choices=["refresh", "start", "stop", "restart", "enable", "disable"])
    p_svc.add_argument("--target",  required=True, choices=["companion", "relay"])
    p_svc.add_argument("--service")

    # wfb-config — edit wifibroadcast.cfg safely (watchdog apply + rollback)
    p_wfb = sub.add_parser("wfb-config")
    p_wfb.add_argument("action", choices=[
        "get", "params", "set", "set-both", "restore-default", "confirm",
        "check-secondary"])
    p_wfb.add_argument("--target", choices=["companion", "relay"])
    p_wfb.add_argument("--params", help="comma list: section.key=value "
                       "(e.g. base.mcs_index=2,video.fec_k=8)")
    p_wfb.add_argument("--danger-ack", action="store_true",
                       help="acknowledge a TIER2 (both-ends) change")
    p_wfb.add_argument("--timeout", help="watchdog rollback timeout seconds (default 60)")

    # status — fast reachability check, no password needed
    sub.add_parser("status")

    # config
    p_cfg = sub.add_parser("config")
    p_cfg.add_argument("action", choices=["show", "set"])
    p_cfg.add_argument("--primary-ip")
    p_cfg.add_argument("--primary-port")
    p_cfg.add_argument("--secondary-ip")
    p_cfg.add_argument("--secondary-port")
    p_cfg.add_argument("--username")
    p_cfg.add_argument("--companion-password")
    p_cfg.add_argument("--relay-ip")
    p_cfg.add_argument("--relay-ssh-port")
    p_cfg.add_argument("--relay-username")
    p_cfg.add_argument("--relay-password")

    args = parser.parse_args()
    cfg  = load_config()

    if args.cmd == "companion":
        return companion_actions(args, cfg)
    if args.cmd == "relay":
        return relay_actions(args, cfg)
    if args.cmd == "services":
        return services_actions(args, cfg)
    if args.cmd == "wfb-config":
        return wfb_config_actions(args, cfg)
    if args.cmd == "config":
        return config_actions(args, cfg)
    if args.cmd == "status":
        return status_actions(cfg)
    return 1


if __name__ == "__main__":
    sys.exit(main())
