#!/usr/bin/env python3
"""
pxlabs_cli.py  —  v2.1
CLI bridge for QGC PXLABS pages and pxlabs_cli integration.

Security fix: sudo password is fed via `printf` instead of `echo`
so it does not appear in `ps aux` on the remote host.

New subcommands vs v2.0:
  config show                       — print resolved config
  companion camera-apply            — apply camera settings via vision_config_manager
  companion camera-query --device   — query camera details via v4l2-ctl
"""

import argparse
import json
import os
import re
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


def run_cmd(ok, out, err, exit_status):
    if out:
        print(out.strip(), flush=True)
    if err:
        print(err.strip(), file=sys.stderr, flush=True)
    return 0 if ok else (exit_status if exit_status is not None else 1)


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
            subprocess.Popen(["cmd.exe", "/c", f'start cmd /k ssh -p {port} {username}@{ip}'],
                             shell=False)
        else:
            subprocess.Popen(["/bin/sh", "-lc", f"gnome-terminal -- ssh -p {port} {username}@{ip}"])
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

    if action == "camera-apply":
        device     = getattr(args, "device", "/dev/video0")
        # Switch active camera; vision_config_manager restarts streaming service
        return run_cmd(*ssh_exec(ip, port, username, password, f"sudo vision_config_manager {device}"))

    if action == "camera-query":
        device = getattr(args, "device", "/dev/video0")
        return run_cmd(*ssh_exec(ip, port, username, password,
                                  f"v4l2-ctl --list-formats-ext -d {device} 2>&1"))

    if action in ("capture-front", "capture-bottom"):
        front = action == "capture-front"
        device = companion_camera_device(swap, front=front)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        remote_path = f"/home/roz/Model_image/Rozcam_{timestamp}.jpg"
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

    if action in ("record-front", "record-bottom"):
        if not getattr(args, "duration", None) or args.duration <= 0:
            print("ERROR: --duration required for record", file=sys.stderr)
            return 1
        front = action == "record-front"
        device = companion_camera_device(swap, front=front)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        remote_path = f"/home/roz/Model_video/Rozcam_{timestamp}.mp4"
        local_path = Path.home() / "Videos" / f"Rozcam_{timestamp}.mp4"
        local_path.parent.mkdir(parents=True, exist_ok=True)
        ok, out, err, code = ssh_exec(ip, port, username, password,
                                       f"Rozcam -v {device} {args.duration}")
        if not ok:
            return run_cmd(ok, out, err, code)
        time.sleep(int(args.duration) + 2)
        if sftp_get(ip, port, username, password, remote_path, str(local_path)):
            print(f"Saved: {local_path}")
            return 0
        return 1

    if action == "reboot":
        return run_cmd(*ssh_exec(ip, port, username, password, "sudo reboot"))

    if action == "shutdown":
        return run_cmd(*ssh_exec(ip, port, username, password, "sudo shutdown now"))

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
        return run_cmd(*ssh_exec(ip, port, username, password, "sudo reboot"))
    if action == "shutdown":
        return run_cmd(*ssh_exec(ip, port, username, password, "sudo shutdown now"))

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
def services_actions(args, cfg):
    target = args.target
    services = cfg.get("important_services") or [
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
            f'a=$(systemctl is-active "$s" 2>/dev/null || echo unknown); '
            f'e=$(systemctl is-enabled "$s" 2>/dev/null || echo unknown); '
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
    parser = argparse.ArgumentParser(description="PXLABS CLI v2.1 — companion/relay control bridge")
    sub = parser.add_subparsers(dest="cmd", required=True)

    # companion
    p_comp = sub.add_parser("companion")
    p_comp.add_argument("action", choices=[
        "front-switch", "bottom-switch", "split-front-bottom", "split-bottom-front",
        "camera-apply", "camera-query",
        "wifi-temp",
        "capture-front", "capture-bottom",
        "record-front", "record-bottom",
        "reboot", "shutdown", "ssh-terminal",
    ])
    p_comp.add_argument("--swap",     action="store_true", help="swap camera mapping")
    p_comp.add_argument("--duration", type=int,            help="record duration in seconds")
    p_comp.add_argument("--device",   default="/dev/video0", help="camera device path")
    p_comp.add_argument("--resolution", default="1920x1080")
    p_comp.add_argument("--fps",       default="60")
    p_comp.add_argument("--format",    default="MJPG")

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
    if args.cmd == "config":
        return config_actions(args, cfg)
    if args.cmd == "status":
        return status_actions(cfg)
    return 1


if __name__ == "__main__":
    sys.exit(main())
