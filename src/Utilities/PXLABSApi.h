// PXLABS integration — additive file, do not modify existing QGC code
//
// PXLABSApi — the typed facade over PXLABSCommandBus. Registered in QML as the
// singleton `Pxlabs`. Every companion/relay command is defined exactly once,
// here, with real argument types. QML calls read like an API instead of
// hand-built command strings:
//
//     Pxlabs.companion.switchCamera("front")
//     Pxlabs.companion.setCamParams(dev, res, fps, fmt)   // args escaped
//     Pxlabs.relay.wfbSwitch("cluster")
//     Pxlabs.status()
//
// Each call returns a PXLABSRequest whose signals route back to that caller,
// which is what lets the panels drop their busy/abort/retry/mutex machinery.

#pragma once

#include <QObject>
#include <QString>
#include <QVariantMap>

#include "PXLABSCommandBus.h"

// ---------------------------------------------------------------------------
// PXLABSNode — commands common to every node (companion and relay).
class PXLABSNode : public QObject
{
    Q_OBJECT

public:
    PXLABSNode(QString name, PXLABSCommandBus* bus, QObject* parent = nullptr)
        : QObject(parent), _name(std::move(name)), _bus(bus) {}

    // Power / access
    Q_INVOKABLE PXLABSRequest* reboot()      { return _run({_name, QStringLiteral("reboot")}); }
    Q_INVOKABLE PXLABSRequest* shutdown()    { return _run({_name, QStringLiteral("shutdown")}); }
    Q_INVOKABLE PXLABSRequest* sshTerminal() { return _run({_name, QStringLiteral("ssh-terminal")}); }

    // WFB config (wifibroadcast.cfg) — watchdog apply with auto-rollback.
    // `wfb-config <action> --target <node> [...]`
    Q_INVOKABLE PXLABSRequest* wfbCfgParams() { return _wfbCfg(QStringLiteral("params")); }
    Q_INVOKABLE PXLABSRequest* wfbCfgGet()    { return _wfbCfg(QStringLiteral("get")); }

    // params: "section.key=value,..." (validated CLI-side). TIER2 keys
    // (channel/bandwidth) additionally need dangerAck + reachable secondary.
    Q_INVOKABLE PXLABSRequest* wfbCfgSet(const QString& params, bool dangerAck = false,
                                         int timeoutS = 60)
    {
        QStringList args { QStringLiteral("wfb-config"), QStringLiteral("set"),
                           QStringLiteral("--target"),  _name,
                           QStringLiteral("--params"),  params,
                           QStringLiteral("--timeout"), QString::number(timeoutS) };
        if (dangerAck) {
            args << QStringLiteral("--danger-ack");
        }
        return _run(args);
    }

    Q_INVOKABLE PXLABSRequest* wfbCfgRestoreDefault(int timeoutS = 60)
    {
        return _run({QStringLiteral("wfb-config"), QStringLiteral("restore-default"),
                     QStringLiteral("--target"),  _name,
                     QStringLiteral("--timeout"), QString::number(timeoutS)});
    }

    // systemd services — `services <action> --target <node> [--service <name>]`
    Q_INVOKABLE PXLABSRequest* servicesRefresh()                 { return _svc(QStringLiteral("refresh")); }
    Q_INVOKABLE PXLABSRequest* serviceStart(const QString& name)   { return _svc(QStringLiteral("start"),   name); }
    Q_INVOKABLE PXLABSRequest* serviceStop(const QString& name)    { return _svc(QStringLiteral("stop"),    name); }
    Q_INVOKABLE PXLABSRequest* serviceRestart(const QString& name) { return _svc(QStringLiteral("restart"), name); }
    Q_INVOKABLE PXLABSRequest* serviceEnable(const QString& name)  { return _svc(QStringLiteral("enable"),  name); }
    Q_INVOKABLE PXLABSRequest* serviceDisable(const QString& name) { return _svc(QStringLiteral("disable"), name); }

protected:
    PXLABSRequest* _run(const QStringList& args,
                        PXLABSRequest::Priority p = PXLABSRequest::Interactive)
    {
        return _bus->enqueue(args, p);
    }

    QString           _name;
    PXLABSCommandBus* _bus = nullptr;

private:
    PXLABSRequest* _wfbCfg(const QString& action)
    {
        return _run({QStringLiteral("wfb-config"), action,
                     QStringLiteral("--target"), _name});
    }

    PXLABSRequest* _svc(const QString& action, const QString& service = QString())
    {
        QStringList args { QStringLiteral("services"), action,
                           QStringLiteral("--target"), _name };
        if (!service.isEmpty()) {
            args << QStringLiteral("--service") << service;
        }
        return _run(args);
    }
};

// ---------------------------------------------------------------------------
// PXLABSCompanionNode — companion-only commands (camera + wifi telemetry).
class PXLABSCompanionNode : public PXLABSNode
{
    Q_OBJECT

public:
    PXLABSCompanionNode(PXLABSCommandBus* bus, QObject* parent = nullptr)
        : PXLABSNode(QStringLiteral("companion"), bus, parent) {}

    // which: "front" | "bottom" | "split-fb" | "split-bf"
    Q_INVOKABLE PXLABSRequest* switchCamera(const QString& which, bool swap = false);

    Q_INVOKABLE PXLABSRequest* cameraQuery(const QString& device)
    {
        return _run({_name, QStringLiteral("camera-query"), QStringLiteral("--device"), device});
    }

    Q_INVOKABLE PXLABSRequest* setCamParams(const QString& device,
                                            const QString& resolution,
                                            const QString& fps,
                                            const QString& format)
    {
        return _run({_name, QStringLiteral("camera-params"),
                     QStringLiteral("--device"),     device,
                     QStringLiteral("--resolution"), resolution,
                     QStringLiteral("--fps"),        fps,
                     QStringLiteral("--format"),     format});
    }

    // Background telemetry poll — yields to interactive commands.
    Q_INVOKABLE PXLABSRequest* wifiTemp()
    {
        return _run({_name, QStringLiteral("wifi-temp")}, PXLABSRequest::Background);
    }
};

// ---------------------------------------------------------------------------
// PXLABSRelayNode — relay-only commands (WFB-NG control).
class PXLABSRelayNode : public PXLABSNode
{
    Q_OBJECT

public:
    PXLABSRelayNode(PXLABSCommandBus* bus, QObject* parent = nullptr)
        : PXLABSNode(QStringLiteral("relay"), bus, parent) {}

    // `background` true for the SA/CA status poller; false for the button.
    Q_INVOKABLE PXLABSRequest* wfbRefresh(bool background = false)
    {
        return _run({_name, QStringLiteral("wfb"), QStringLiteral("refresh")},
                    background ? PXLABSRequest::Background : PXLABSRequest::Interactive);
    }
    Q_INVOKABLE PXLABSRequest* wfbStatus()     { return _wfb(QStringLiteral("status")); }
    Q_INVOKABLE PXLABSRequest* wfbLogs()       { return _wfb(QStringLiteral("logs")); }
    Q_INVOKABLE PXLABSRequest* wfbViewConfig() { return _wfb(QStringLiteral("view-config")); }
    Q_INVOKABLE PXLABSRequest* wfbListNics()   { return _wfb(QStringLiteral("list-nics")); }

    Q_INVOKABLE PXLABSRequest* wfbSetNics(const QString& nics)
    {
        return _run({_name, QStringLiteral("wfb"), QStringLiteral("set-nics"),
                     QStringLiteral("--nics"), nics});
    }

    // mode: "standalone" | "cluster"
    Q_INVOKABLE PXLABSRequest* wfbSwitch(const QString& mode)
    {
        return _run({_name, QStringLiteral("wfb"), QStringLiteral("switch"),
                     QStringLiteral("--mode"), mode});
    }

private:
    PXLABSRequest* _wfb(const QString& sub)
    {
        return _run({_name, QStringLiteral("wfb"), sub});
    }
};

// ---------------------------------------------------------------------------
// PXLABSApi — the `Pxlabs` singleton. Owns the bus and the two node facades.
class PXLABSApi : public QObject
{
    Q_OBJECT

    Q_PROPERTY(PXLABSCompanionNode* companion  READ companion  CONSTANT)
    Q_PROPERTY(PXLABSRelayNode*     relay       READ relay      CONSTANT)
    Q_PROPERTY(bool                 busy        READ busy       NOTIFY busyChanged)
    Q_PROPERTY(QString              cliPath     READ cliPath    NOTIFY cliPathChanged)
    Q_PROPERTY(QString              pythonPath  READ pythonPath NOTIFY pythonPathChanged)

public:
    explicit PXLABSApi(QObject* parent = nullptr);

    PXLABSCompanionNode* companion() const { return _companion; }
    PXLABSRelayNode*     relay()     const { return _relay; }
    bool                 busy()      const { return _bus->busy(); }
    QString              cliPath()   const { return _bus->cliPath(); }
    QString              pythonPath() const { return _bus->pythonPath(); }

    // Top-level (node-agnostic) commands.
    Q_INVOKABLE PXLABSRequest* status(bool background = false)
    {
        return _bus->enqueue({QStringLiteral("status")},
                             background ? PXLABSRequest::Background : PXLABSRequest::Interactive);
    }
    Q_INVOKABLE PXLABSRequest* configShow()
    {
        return _bus->enqueue({QStringLiteral("config"), QStringLiteral("show")});
    }
    // Is the companion's secondary (non-WFB) route alive? Gates TIER2 changes.
    Q_INVOKABLE PXLABSRequest* wfbCfgCheckSecondary()
    {
        return _bus->enqueue({QStringLiteral("wfb-config"), QStringLiteral("check-secondary")});
    }
    // Apply the same params to BOTH ends (companion first, then relay) with a
    // matched-ends guarantee: neither side is confirmed until both applied, so
    // any failure rolls both back. wifi_txpower is per-side and rejected here.
    Q_INVOKABLE PXLABSRequest* wfbCfgSetBoth(const QString& params, bool dangerAck = false,
                                             int timeoutS = 60)
    {
        QStringList args { QStringLiteral("wfb-config"), QStringLiteral("set-both"),
                           QStringLiteral("--params"),  params,
                           QStringLiteral("--timeout"), QString::number(timeoutS) };
        if (dangerAck) {
            args << QStringLiteral("--danger-ack");
        }
        return _bus->enqueue(args);
    }
    // opts: JS object keyed by CLI flag name without the leading "--", e.g.
    //   { "primary-ip": "10.5.6.101", "username": "pi", "companion-password": "…" }
    // Unknown keys are ignored; values are passed verbatim as QProcess args.
    Q_INVOKABLE PXLABSRequest* configSet(const QVariantMap& opts);

    // Settings passthrough (shares storage with the legacy PXLABSRunner).
    Q_INVOKABLE void setCliPath(const QString& path)    { _bus->setCliPath(path); }
    Q_INVOKABLE void setPythonPath(const QString& path) { _bus->setPythonPath(path); }
    Q_INVOKABLE void abort() {}   // no-op: the queue makes manual aborts unnecessary

signals:
    void busyChanged();
    void cliPathChanged();
    void pythonPathChanged();

private:
    PXLABSCommandBus*    _bus       = nullptr;
    PXLABSCompanionNode* _companion = nullptr;
    PXLABSRelayNode*     _relay     = nullptr;
};
