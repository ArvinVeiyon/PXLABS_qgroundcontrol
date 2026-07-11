// PXLABS integration — additive file, do not modify existing QGC code

#include "PXLABSLinkMonitor.h"

#include <QCoreApplication>
#include <QFile>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcess>
#include <QSettings>

#include <algorithm>
#include <cmath>

namespace {

constexpr int kReconnectMs = 2000;
constexpr int kStaleMs     = 5000;
constexpr int kHistoryLen  = 10;       // seconds of rolling window

// Approximate SNR decode floors, dB (802.11n, 20 MHz, long GI)
int mcsSnrFloor(int mcs)
{
    static const int floors[] = { 2, 5, 9, 11, 15, 18, 20, 25 };
    return (mcs >= 0 && mcs < 8) ? floors[mcs] : 5;
}

// 802.11n PHY data rates, Mbit/s (long GI)
double phyRate(int bw, int mcs)
{
    static const double r20[] = {  6.5, 13.0, 19.5, 26.0, 39.0,  52.0,  58.5,  65.0 };
    static const double r40[] = { 13.5, 27.0, 40.5, 54.0, 81.0, 108.0, 121.5, 135.0 };
    if (mcs < 0 || mcs > 7) {
        return 13.0;
    }
    return (bw == 40) ? r40[mcs] : r20[mcs];
}

// monitor-mode injection can't fill the channel; practical ceiling
constexpr double kUsableAirtime = 0.70;

// [rate, cumulative] counter pair -> per-second rate
double rateOf(const QJsonObject& packets, const char* key)
{
    const QJsonArray v = packets.value(QLatin1String(key)).toArray();
    return v.isEmpty() ? 0.0 : v.at(0).toDouble();
}

// Unified 0-100 signal quality for one antenna, regardless of scale.
// SNR-reporting card (relay rtl8812au): snr_avg / 30 dB. CPE610 (Atheros)
// reports snr=0 and a positive signal-above-noise "rssi" -> 0-40 scale.
double antQuality(const QJsonObject& a)
{
    const double snr = a.value(QLatin1String("snr_avg")).toDouble();
    if (snr > 0) {
        return std::clamp(snr / 30.0 * 100.0, 0.0, 100.0);
    }
    const double v = a.value(QLatin1String("rssi_avg")).toDouble();
    return std::clamp(v / 40.0 * 100.0, 0.0, 100.0);
}

} // namespace

PXLABSLinkMonitor::PXLABSLinkMonitor(QObject* parent)
    : QObject(parent)
{
    QSettings settings;
    settings.beginGroup(QStringLiteral("PXLABSLinkMonitor"));
    _port = settings.value(QStringLiteral("port"), 8103).toInt();
    settings.endGroup();
    _host = _resolveHost();

    connect(&_sock, &QTcpSocket::readyRead,    this, &PXLABSLinkMonitor::_onReadyRead);
    connect(&_sock, &QTcpSocket::connected,    this, &PXLABSLinkMonitor::connectedChanged);
    connect(&_sock, &QTcpSocket::disconnected, this, &PXLABSLinkMonitor::_onDisconnected);
    connect(&_sock, &QTcpSocket::errorOccurred, this, [this](QAbstractSocket::SocketError) {
        emit connectedChanged();
        _retry.start();
    });

    _retry.setSingleShot(true);
    _retry.setInterval(kReconnectMs);
    connect(&_retry, &QTimer::timeout, this, &PXLABSLinkMonitor::_connectNow);

    _stale.setSingleShot(true);
    _stale.setInterval(kStaleMs);
    connect(&_stale, &QTimer::timeout, this, &PXLABSLinkMonitor::_onStale);

    _connectNow();
}

void PXLABSLinkMonitor::setEndpoint(const QString& host, int port)
{
    _host = host;
    _port = port;
    QSettings settings;
    settings.beginGroup(QStringLiteral("PXLABSLinkMonitor"));
    settings.setValue(QStringLiteral("host"), host);
    settings.setValue(QStringLiteral("port"), port);
    settings.endGroup();
    emit endpointChanged();
    _connectNow();
}

void PXLABSLinkMonitor::launchMonitorApp()
{
    // Single instance: a second click while the monitor is open is a no-op.
    // The QProcess is owned by this object, so the monitor closes together
    // with G-Control.
    if (_monitorProc && _monitorProc->state() != QProcess::NotRunning) {
        return;
    }

    QSettings settings;
    settings.beginGroup(QStringLiteral("PXLABSLinkMonitor"));
    const QString dir = settings.value(QStringLiteral("monitorDir"),
                                       QStringLiteral("E:/wfb-link-monitor")).toString();
    settings.endGroup();

    if (!_monitorProc) {
        _monitorProc = new QProcess(this);
    }
    _monitorProc->setWorkingDirectory(dir);

    // pythonw = no console window; fall back to the console launcher if the
    // windowless interpreter isn't on PATH.
    _monitorProc->setProgram(QStringLiteral("pythonw"));
    _monitorProc->setArguments({ QStringLiteral("-m"), QStringLiteral("wfb_link_monitor.main") });
    _monitorProc->start();
    if (!_monitorProc->waitForStarted(3000)) {
        _monitorProc->setProgram(QStringLiteral("cmd.exe"));
        _monitorProc->setArguments({ QStringLiteral("/c"), dir + QStringLiteral("/run_monitor.bat") });
        _monitorProc->start();
    }
}

// Host precedence: explicit setEndpoint() override (QSettings) → relay_ip
// from the CLI's ssh_config.json (single source of truth, follows the
// Connection page) → compiled-in default.
QString PXLABSLinkMonitor::_resolveHost() const
{
    QSettings settings;
    settings.beginGroup(QStringLiteral("PXLABSLinkMonitor"));
    const QString overrideHost = settings.value(QStringLiteral("host")).toString();
    settings.endGroup();
    if (!overrideHost.isEmpty()) {
        return overrideHost;
    }

    QFile cfg(QCoreApplication::applicationDirPath() + QStringLiteral("/config/ssh_config.json"));
    if (cfg.open(QIODevice::ReadOnly)) {
        const QString relayIp = QJsonDocument::fromJson(cfg.readAll()).object()
                                    .value(QLatin1String("relay_ip")).toString();
        if (!relayIp.isEmpty()) {
            return relayIp;
        }
    }
    return QStringLiteral("10.5.6.101");
}

void PXLABSLinkMonitor::_connectNow()
{
    // Re-resolve each attempt so a relay re-address is picked up live.
    const QString host = _resolveHost();
    if (host != _host) {
        _host = host;
        emit endpointChanged();
    }
    _sock.abort();
    _buf.clear();
    _sock.connectToHost(_host, static_cast<quint16>(_port));
}

void PXLABSLinkMonitor::_onDisconnected()
{
    emit connectedChanged();
    _resetStats();
    _retry.start();
}

void PXLABSLinkMonitor::_onStale()
{
    // Connected but silent — the wfb service on the relay stopped publishing.
    _resetStats();
}

void PXLABSLinkMonitor::_resetStats()
{
    _streams.clear();
    _live = false;
    _linkPct = -1;
    _airPct = -1;
    _state = QStringLiteral("OFFLINE");
    _limitingStream.clear();
    _bestRssi = 0;
    _bestSnr = 0;
    _mcs = -1;
    _airMbit = 0;
    _usableMbit = 0;
    _fecPerSec = 0;
    _lostPerSec = 0;
    _antennas.clear();
    emit statsChanged();
}

void PXLABSLinkMonitor::_onReadyRead()
{
    _buf += _sock.readAll();
    int nl;
    while ((nl = _buf.indexOf('\n')) >= 0) {
        const QByteArray line = _buf.left(nl).trimmed();
        _buf.remove(0, nl + 1);
        if (line.isEmpty()) {
            continue;
        }
        const QJsonDocument doc = QJsonDocument::fromJson(line);
        if (doc.isObject()) {
            _handleMessage(doc.object());
        }
    }
}

void PXLABSLinkMonitor::_handleMessage(const QJsonObject& msg)
{
    const QString type = msg.value(QLatin1String("type")).toString();
    if (type == QLatin1String("settings")) {
        _handleSettings(msg);
        return;
    }
    if (type != QLatin1String("rx") && type != QLatin1String("tx")) {
        return;
    }

    const QString id = msg.value(QLatin1String("id")).toString(QStringLiteral("unknown"));
    Stream& s = _streams[id];
    s.isRx = (type == QLatin1String("rx"));
    s.lastMsg = msg;

    const QJsonObject packets = msg.value(QLatin1String("packets")).toObject();
    Entry e;
    if (s.isRx) {
        e.all    = rateOf(packets, "all");
        e.lost   = rateOf(packets, "lost");
        e.fecRec = rateOf(packets, "fec_rec");
        // best snr among antennas that actually report SNR (relay card)
        for (const QJsonValue& av : msg.value(QLatin1String("rx_ant_stats")).toArray()) {
            const double snr = av.toObject().value(QLatin1String("snr_avg")).toDouble();
            if (snr > 0) {
                e.snr = std::max(e.snr, snr);
            }
        }
    }
    s.hist.append(e);
    if (s.hist.size() > kHistoryLen) {
        s.hist.remove(0, s.hist.size() - kHistoryLen);
    }

    _stale.start();
    _recompute();
}

void PXLABSLinkMonitor::_handleSettings(const QJsonObject& msg)
{
    // Map node IP -> first wlan name. The antenna id encodes server_address
    // for the local node while the config lists it as 127.0.0.1; standalone
    // mode has no cluster nodes and ant ids decode to 0.0.0.0.
    _nodeNames.clear();
    const QJsonObject cluster = msg.value(QLatin1String("settings")).toObject()
                                   .value(QLatin1String("cluster")).toObject();
    const QJsonObject nodes = cluster.value(QLatin1String("nodes")).toObject();
    const QString server = cluster.value(QLatin1String("server_address")).toString();

    for (auto it = nodes.constBegin(); it != nodes.constEnd(); ++it) {
        const QJsonArray wlans = it.value().toObject().value(QLatin1String("wlans")).toArray();
        const QString label = wlans.isEmpty() ? it.key() : wlans.at(0).toString();
        QString ipStr = it.key();
        if (ipStr == QLatin1String("127.0.0.1") && !server.isEmpty()) {
            ipStr = server;
        }
        const QHostAddress addr(ipStr);
        _nodeNames.insert(addr.toIPv4Address(), label);
    }
    if (_nodeNames.isEmpty()) {
        const QJsonArray wlans = msg.value(QLatin1String("wlans")).toArray();
        const QString local = wlans.isEmpty() ? QStringLiteral("local") : wlans.at(0).toString();
        _nodeNames.insert(0, local);
        _nodeNames.insert(QHostAddress(QStringLiteral("127.0.0.1")).toIPv4Address(), local);
    }
}

QString PXLABSLinkMonitor::_nodeName(quint32 ip) const
{
    const auto it = _nodeNames.constFind(ip);
    if (it != _nodeNames.constEnd()) {
        return it.value();
    }
    return QHostAddress(ip).toString();
}

// 0-100 quality of one rx stream. 100 = clean. Penalties: real loss
// (dominant), FEC pressure, shrinking SNR margin. Port of model.py quality().
double PXLABSLinkMonitor::_quality(const Stream& s) const
{
    double q = 100.0;
    double lost = 0, fec = 0, all = 0, lastSnr = -1;
    for (const Entry& e : s.hist) {
        lost += e.lost;
        fec  += e.fecRec;
        all  += e.all;
        if (e.snr > 0) {
            lastSnr = e.snr;
        }
    }
    if (all <= 0) {
        all = 1;
    }
    if (lost > 0) {
        q = 25.0 - std::min(lost, 20.0);          // any real loss => bad
    }
    q -= std::min(40.0, 400.0 * fec / all);       // FEC pressure: up to -40

    // SNR margin above the decode floor for the current MCS (relay card only)
    int mcs = -1;
    for (const QJsonValue& av : s.lastMsg.value(QLatin1String("rx_ant_stats")).toArray()) {
        const QJsonObject a = av.toObject();
        if (a.contains(QLatin1String("mcs"))) {
            mcs = a.value(QLatin1String("mcs")).toInt();
            break;
        }
    }
    if (lastSnr > 0 && mcs >= 0) {
        const double margin = lastSnr - mcsSnrFloor(mcs);
        if (margin < 15) {
            q -= (15 - margin) * 3.0;             // margin erosion, -45 at the cliff
        }
    }
    return std::clamp(q, 0.0, 100.0);
}

// Estimated on-air Mbit/s of one stream. rx: all_bytes sums frames over every
// listening wlan, so scale by the busiest wlan's share to get true air
// occupancy. tx: injected_bytes is already on-air.
double PXLABSLinkMonitor::_airMbitOf(const Stream& s) const
{
    const QJsonObject packets = s.lastMsg.value(QLatin1String("packets")).toObject();
    if (!s.isRx) {
        return rateOf(packets, "injected_bytes") * 8 / 1e6;
    }
    const double allBytes = rateOf(packets, "all_bytes");
    QHash<qint64, double> perWlan;                // node+wlan (ant id >> 8)
    for (const QJsonValue& av : s.lastMsg.value(QLatin1String("rx_ant_stats")).toArray()) {
        const QJsonObject a = av.toObject();
        const qint64 key = a.value(QLatin1String("ant")).toInteger() >> 8;
        perWlan[key] = std::max(perWlan[key], a.value(QLatin1String("pkt_recv")).toDouble());
    }
    double total = 0, best = 0;
    for (double v : perWlan) {
        total += v;
        best = std::max(best, v);
    }
    const double frac = (total > 0) ? best / total : 1.0;
    return allBytes * frac * 8 / 1e6;
}

void PXLABSLinkMonitor::_recompute()
{
    _live = true;

    // Worst rx stream = the link quality; its antennas populate the drawer.
    const Stream* worst = nullptr;
    double worstQ = 1e9;
    double air = 0;
    _fecPerSec = 0;
    _lostPerSec = 0;
    _mcs = -1;
    _bw = 20;

    for (auto it = _streams.constBegin(); it != _streams.constEnd(); ++it) {
        const Stream& s = it.value();
        air += _airMbitOf(s);
        if (!s.isRx || s.hist.isEmpty()) {
            continue;
        }
        _fecPerSec  += s.hist.last().fecRec;
        _lostPerSec += s.hist.last().lost;
        for (const QJsonValue& av : s.lastMsg.value(QLatin1String("rx_ant_stats")).toArray()) {
            const QJsonObject a = av.toObject();
            if (_mcs < 0 && a.contains(QLatin1String("mcs"))) {
                _mcs = a.value(QLatin1String("mcs")).toInt();
                _bw  = a.value(QLatin1String("bw")).toInt(20);
            }
        }
        const double q = _quality(s);
        if (q < worstQ) {
            worstQ = q;
            worst = &s;
            _limitingStream = it.key();
        }
    }

    _linkPct = worst ? static_cast<int>(std::lround(worstQ)) : -1;

    if (_mcs >= 0) {
        _usableMbit = phyRate(_bw, _mcs) * kUsableAirtime;
        _airMbit = air;
        _airPct = static_cast<int>(std::lround(
            std::clamp(air / _usableMbit * 100.0, 0.0, 100.0)));
    } else {
        _airPct = -1;
        _airMbit = 0;
        _usableMbit = 0;
    }

    // Best RSSI/SNR + antenna rows from the limiting stream (true-dBm
    // antennas only for the headline numbers).
    _bestRssi = 0;
    _bestSnr = 0;
    _antennas.clear();
    if (worst) {
        for (const QJsonValue& av : worst->lastMsg.value(QLatin1String("rx_ant_stats")).toArray()) {
            const QJsonObject a = av.toObject();
            const qint64 ant = a.value(QLatin1String("ant")).toInteger();
            const double snr = a.value(QLatin1String("snr_avg")).toDouble();
            const double rssi = a.value(QLatin1String("rssi_avg")).toDouble();
            if (snr > 0) {
                _bestSnr  = std::max(_bestSnr,  static_cast<int>(std::lround(snr)));
                _bestRssi = (_bestRssi == 0) ? static_cast<int>(std::lround(rssi))
                                             : std::max(_bestRssi, static_cast<int>(std::lround(rssi)));
            }
            QVariantMap row;
            row.insert(QStringLiteral("label"),
                       _nodeName(static_cast<quint32>((ant >> 32) & 0xFFFFFFFF))
                       + QStringLiteral(":") + QString::number(ant & 0xFF));
            row.insert(QStringLiteral("quality"), static_cast<int>(std::lround(antQuality(a))));
            row.insert(QStringLiteral("rssi"), static_cast<int>(std::lround(rssi)));
            row.insert(QStringLiteral("snr"), static_cast<int>(std::lround(snr)));
            _antennas.append(row);
        }
    }

    // Overall state — chip color.
    if (_linkPct < 0) {
        _state = QStringLiteral("OFFLINE");
    } else if (_lostPerSec > 0 || (_airPct >= 0 && _airPct > 85) || _linkPct < 50) {
        _state = QStringLiteral("CRIT");
    } else if (_linkPct < 80 || (_airPct >= 0 && _airPct > 60)) {
        _state = QStringLiteral("WARN");
    } else {
        _state = QStringLiteral("GOOD");
    }

    emit statsChanged();
}
