// PXLABS integration — additive file, do not modify existing QGC code

#include "PXLABSApi.h"

#include <QSet>

// ---------------------------------------------------------------------------

PXLABSApi::PXLABSApi(QObject* parent)
    : QObject(parent)
    , _bus(new PXLABSCommandBus(this))
    , _companion(new PXLABSCompanionNode(_bus, this))
    , _relay(new PXLABSRelayNode(_bus, this))
{
    // Re-expose the bus state changes as the facade's own notifications.
    connect(_bus, &PXLABSCommandBus::busyChanged,       this, &PXLABSApi::busyChanged);
    connect(_bus, &PXLABSCommandBus::cliPathChanged,    this, &PXLABSApi::cliPathChanged);
    connect(_bus, &PXLABSCommandBus::pythonPathChanged, this, &PXLABSApi::pythonPathChanged);
}

// ---------------------------------------------------------------------------

PXLABSRequest* PXLABSApi::configSet(const QVariantMap& opts)
{
    // Whitelist of accepted flags — this is the single source of truth for the
    // `config set` argument vocabulary. Anything else in `opts` is ignored.
    static const QSet<QString> kAllowed {
        QStringLiteral("primary-ip"),        QStringLiteral("primary-port"),
        QStringLiteral("secondary-ip"),      QStringLiteral("secondary-port"),
        QStringLiteral("username"),          QStringLiteral("companion-password"),
        QStringLiteral("relay-ip"),          QStringLiteral("relay-ssh-port"),
        QStringLiteral("relay-username"),    QStringLiteral("relay-password"),
    };

    QStringList args { QStringLiteral("config"), QStringLiteral("set") };
    for (auto it = opts.constBegin(); it != opts.constEnd(); ++it) {
        if (!kAllowed.contains(it.key())) {
            continue;
        }
        const QString value = it.value().toString();
        if (value.isEmpty()) {
            continue;
        }
        args << (QStringLiteral("--") + it.key()) << value;
    }
    return _bus->enqueue(args);
}

// ---------------------------------------------------------------------------

PXLABSRequest* PXLABSCompanionNode::switchCamera(const QString& which, bool swap)
{
    // Map the facade's short names to the CLI subcommands.
    QString sub;
    if (which == QLatin1String("front")) {
        sub = QStringLiteral("front-switch");
    } else if (which == QLatin1String("bottom")) {
        sub = QStringLiteral("bottom-switch");
    } else if (which == QLatin1String("split-fb")) {
        sub = QStringLiteral("split-front-bottom");
    } else if (which == QLatin1String("split-bf")) {
        sub = QStringLiteral("split-bottom-front");
    } else {
        sub = which;   // pass through — let the CLI reject anything unexpected
    }

    QStringList args { _name, sub };
    if (swap) {
        args << QStringLiteral("--swap");
    }
    return _run(args);
}
