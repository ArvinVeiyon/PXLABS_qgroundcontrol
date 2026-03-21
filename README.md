
# G-Control — PXLABS Edition

> **This is the PXLABS fork of QGroundControl** — a customised GCS for the Vind-Roz drone system (RPi5 companion + PX4 + WFB-NG relay).
> Built on **QGroundControl v5.0.8** with additive-only integration. No upstream QGC code is removed or replaced.

| | |
|---|---|
| **App name** | G-Control |
| **Base** | QGroundControl v5.0.8 |
| **Branch** | `PXLABS-v2.1-integration` |
| **Latest release** | `release/PXLABS-v2.2` · tag `PXLABS-v2.2.0` |
| **Installer** | `G-Control-Setup-v2.2.0.exe` (~117 MB, no dependencies) |
| **Build** | VS2022 + Qt 6.8.3 + GStreamer 1.22.12 |
| **Companion** | Vind-Roz · RPi5 8GB · Ubuntu 24.04 · ROS2 Jazzy · PX4 v1.16.0-rc1 |
| **Relay** | Vind-Rly · RPi5 · Ubuntu 24.04 · wifibroadcast@gs |

## PXLABS Features

- **System Control panel** — right-edge resizable slide-out: companion + relay power, SSH terminal, WFB standalone/cluster mode switch with live status glyph on pull tab
- **Air-TX Temp chip** — live WFB RF card temperature in toolbar (green/orange/red colour-coded)
- **Connection Status chips** — Comp + Relay reachability dots in toolbar, auto-refresh every 30 s
- **Camera switch panel** — draggable front/bottom/split-front-bottom/split-bottom-front
- **Camera Device Advanced** — query full camera detail, set resolution/fps/format via `vision_config_manager`
- **Settings pages** — Connection (SSH config), PXLABS Settings, Companion Control, Relay Station
- **Windows installer** — `G-Control-Setup-v2.2.0.exe`, no Python or manual DLL setup needed

## Quick Start

### Install (end users)
Run `G-Control-Setup-v2.2.0.exe` → installs to `C:\Program Files\G-Control\`, creates shortcuts, sets GStreamer env automatically.
First launch: Settings → Connection → enter SSH credentials → Apply.

### Build from source (developers)
```
1. Build   →  run build_pxlabs.bat  (requires VS2022 + Qt 6.8.3 in PATH)
2. Deploy  →  deploy_dlls.bat runs automatically after build
3. Launch  →  Launch-GControl.bat  (sets GStreamer env vars)
4. Setup   →  Settings → Connection → enter SSH credentials → Apply
```

## Documentation

| Document | Purpose |
|----------|---------|
| [PXLABS_CHANGES.md](PXLABS_CHANGES.md) | Technical change log — all modified/added files, CLI reference, QML patterns, session notes |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Development journal — full session history, bug log, architecture notes, build reference |

## Reference

Original unmodified QGC v5.0.8 is kept at `E:\qgroundcontrol` (local reference only).
Upstream: [github.com/mavlink/qgroundcontrol](https://github.com/mavlink/qgroundcontrol)

---

<p align="center">
  <img src="https://raw.githubusercontent.com/Dronecode/UX-Design/35d8148a8a0559cd4bcf50bfa2c94614983cce91/QGC/Branding/Deliverables/QGC_RGB_Logo_Horizontal_Positive_PREFERRED/QGC_RGB_Logo_Horizontal_Positive_PREFERRED.svg" alt="QGroundControl Logo" width="500">
</p>

<p align="center">
  <a href="https://github.com/mavlink/QGroundControl/releases">
    <img src="https://img.shields.io/github/release/mavlink/QGroundControl.svg" alt="Latest Release">
  </a>
</p>

*QGroundControl* (QGC) is a highly intuitive and powerful Ground Control Station (GCS) designed for UAVs. Whether you're a first-time pilot or an experienced professional, QGC provides a seamless user experience for flight control and mission planning, making it the go-to solution for any *MAVLink-enabled drone*.

---

### 🌟 *Why Choose QGroundControl?*

- *🚀 Ease of Use*: A beginner-friendly interface designed for smooth operation without sacrificing advanced features for pros.
- *✈️ Comprehensive Flight Control*: Full flight control and mission management for *PX4* and *ArduPilot* powered UAVs.
- *🛠️ Mission Planning*: Easily plan complex missions with a simple drag-and-drop interface.

🔍 For a deeper dive into using QGC, check out the [User Manual](https://docs.qgroundcontrol.com/en/) – although, thanks to QGC's intuitive UI, you may not even need it!


---

### 🚁 *Key Features*

- 🕹️ *Full Flight Control*: Supports all *MAVLink drones*.
- ⚙️ *Vehicle Setup*: Tailored configuration for *PX4* and *ArduPilot* platforms.
- 🔧 *Fully Open Source*: Customize and extend the software to suit your needs.

🎯 Check out the latest updates in our [New Features and Release Notes](https://github.com/mavlink/qgroundcontrol/blob/master/ChangeLog.md).

---

### 💻 *Get Involved!*

QGroundControl is *open-source*, meaning you have the power to shape it! Whether you're fixing bugs, adding features, or customizing for your specific needs, QGC welcomes contributions from the community.

🛠️ Start building today with our [Developer Guide](https://dev.qgroundcontrol.com/en/) and [build instructions](https://dev.qgroundcontrol.com/en/getting_started/).

---

### 🔗 *Useful Links*

- 🌐 [Official Website](http://qgroundcontrol.com)
- 📘 [User Manual](https://docs.qgroundcontrol.com/en/)
- 🛠️ [Developer Guide](https://dev.qgroundcontrol.com/en/)
- 💬 [Discussion & Support](https://docs.qgroundcontrol.com/en/Support/Support.html)
- 🤝 [Contributing](https://dev.qgroundcontrol.com/en/contribute/)
- 📜 [License Information](https://github.com/mavlink/qgroundcontrol/blob/master/.github/COPYING.md)

---

With QGroundControl, you're in full command of your UAV, ready to take your missions to the next level.
