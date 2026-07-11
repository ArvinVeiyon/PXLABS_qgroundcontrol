// PXLABS integration — additive file, do not modify existing QGC code
//
// PXLABSLinkMonitor — live WFB-NG link health for the toolbar chip.
//
// Connects directly to the wfb-ng JSON API on the relay (one JSON object per
// line, ~1 Hz per stream). The host follows relay_ip in the CLI's
// config/ssh_config.json — single source of truth with every SSH command —
// unless overridden via setEndpoint(); port defaults to 8103. Derives:
//
//   linkPct  0-100  worst rx-stream quality (loss dominant, then FEC
//                   pressure, then SNR-margin erosion) — port of the proven
//                   wfb-link-monitor model
//   airPct   0-100  on-air Mbit/s vs the practical channel ceiling
//                   (PHY rate for current MCS/bw × 70 % usable airtime)
//
// Registered in QML as the singleton `PxlabsLink`. The math and the schema
// quirks (packet counters are [rate, cumulative] pairs; CPE610 reports
// snr=0 and a positive signal-above-noise "rssi") are documented in
// E:\wfb-link-monitor and WFB_LINK_TELEMETRY.md.

#pragma once

#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QTcpSocket>
#include <QTimer>
#include <QVariantList>
#include <QVector>

class PXLABSLinkMonitor : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool         connected      READ connected      NOTIFY connectedChanged)
    Q_PROPERTY(bool         live           READ live           NOTIFY statsChanged)   // fresh data in the last 5 s
    Q_PROPERTY(int          linkPct        READ linkPct        NOTIFY statsChanged)   // -1 unknown
    Q_PROPERTY(int          airPct         READ airPct         NOTIFY statsChanged)   // -1 unknown
    Q_PROPERTY(QString      state          READ state          NOTIFY statsChanged)   // GOOD/WARN/CRIT/OFFLINE
    Q_PROPERTY(QString      limitingStream READ limitingStream NOTIFY statsChanged)
    Q_PROPERTY(int          bestRssi       READ bestRssi       NOTIFY statsChanged)   // dBm, 0 unknown
    Q_PROPERTY(int          bestSnr        READ bestSnr        NOTIFY statsChanged)   // dB, 0 unknown
    Q_PROPERTY(int          mcs            READ mcs            NOTIFY statsChanged)   // -1 unknown
    Q_PROPERTY(int          bandwidth      READ bandwidth      NOTIFY statsChanged)
    Q_PROPERTY(double       airMbit        READ airMbit        NOTIFY statsChanged)
    Q_PROPERTY(double       usableMbit     READ usableMbit     NOTIFY statsChanged)
    Q_PROPERTY(double       fecPerSec      READ fecPerSec      NOTIFY statsChanged)
    Q_PROPERTY(double       lostPerSec     READ lostPerSec     NOTIFY statsChanged)
    Q_PROPERTY(QVariantList antennas       READ antennas       NOTIFY statsChanged)   // [{label,quality,rssi,snr}]
    Q_PROPERTY(QString      endpoint       READ endpoint       NOTIFY endpointChanged)

public:
    explicit PXLABSLinkMonitor(QObject* parent = nullptr);

    bool         connected()      const { return _sock.state() == QAbstractSocket::ConnectedState; }
    bool         live()           const { return _live; }
    int          linkPct()        const { return _linkPct; }
    int          airPct()         const { return _airPct; }
    QString      state()          const { return _state; }
    QString      limitingStream() const { return _limitingStream; }
    int          bestRssi()       const { return _bestRssi; }
    int          bestSnr()        const { return _bestSnr; }
    int          mcs()            const { return _mcs; }
    int          bandwidth()      const { return _bw; }
    double       airMbit()        const { return _airMbit; }
    double       usableMbit()     const { return _usableMbit; }
    double       fecPerSec()      const { return _fecPerSec; }
    double       lostPerSec()     const { return _lostPerSec; }
    QVariantList antennas()       const { return _antennas; }
    QString      endpoint()       const { return _host + ":" + QString::number(_port); }

    Q_INVOKABLE void setEndpoint(const QString& host, int port);

    // Launch the standalone PyQt WFB Link Monitor (deep-dive window; future
    // antenna-tracker control). Location overridable via QSettings
    // PXLABSLinkMonitor/monitorDir; defaults to E:/wfb-link-monitor.
    Q_INVOKABLE void launchMonitorApp();

signals:
    void connectedChanged();
    void statsChanged();
    void endpointChanged();

private slots:
    void _onReadyRead();
    void _onDisconnected();
    void _connectNow();
    void _onStale();

private:
    // One second of one stream's counters (the feed publishes ~1 Hz).
    struct Entry {
        double all = 0, lost = 0, fecRec = 0;
        double snr = -1;                       // -1 = no SNR-reporting antenna
    };
    struct Stream {
        bool           isRx = false;
        QVector<Entry> hist;                   // last 10 entries
        QJsonObject    lastMsg;
    };

    QString _resolveHost() const;
    void   _handleMessage(const QJsonObject& msg);
    void   _handleSettings(const QJsonObject& msg);
    void   _recompute();
    void   _resetStats();
    double _quality(const Stream& s) const;
    double _airMbitOf(const Stream& s) const;
    QString _nodeName(quint32 ip) const;

    QTcpSocket _sock;
    QTimer     _retry;
    QTimer     _stale;
    QByteArray _buf;
    class QProcess* _monitorProc = nullptr;    // the launched PyQt monitor

    QString _host;
    int     _port = 8103;

    QHash<QString, Stream>  _streams;
    QHash<quint32, QString> _nodeNames;        // ip (host order) -> wlan label

    bool         _live = false;
    int          _linkPct = -1, _airPct = -1;
    QString      _state = QStringLiteral("OFFLINE");
    QString      _limitingStream;
    int          _bestRssi = 0, _bestSnr = 0, _mcs = -1, _bw = 20;
    double       _airMbit = 0, _usableMbit = 0, _fecPerSec = 0, _lostPerSec = 0;
    QVariantList _antennas;
};
