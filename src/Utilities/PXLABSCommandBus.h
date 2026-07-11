// PXLABS integration — additive file, do not modify existing QGC code
//
// PXLABSCommandBus: the correlated, queued transport under the Pxlabs API layer.
//
// Replaces the "one QProcess behind one _running bool, global signals" model of
// PXLABSCommandRunner. Every call returns a PXLABSRequest whose signals carry
// results back to *only that caller* — no more per-panel flag/mutex/retry hacks.
//
//   * run() never rejects — it enqueues and returns a request id.
//   * Interactive requests preempt a running Background poll (fixes the
//     "camera click did nothing while wifi-temp was polling" root cause / B1).
//   * Duplicate pending Background polls coalesce.
//   * Arguments are passed as a QStringList straight to QProcess — no shell,
//     no space-splitting (fixes shell-injection B4 and arg-splitting B5).

#pragma once

#include <QList>
#include <QObject>
#include <QProcess>
#include <QString>
#include <QStringList>

// ---------------------------------------------------------------------------
// PXLABSRequest — one correlated command. Returned by every facade call.
// QML connects to its signals transiently:
//     var req = Pxlabs.companion.switchCamera("front")
//     req.outputChanged.connect(function() { area.text = req.output })
//     req.succeeded.connect(function(code) { ... })
//     req.failed.connect(function(err)    { area.text = err })
class PXLABSRequest : public QObject
{
    Q_OBJECT

    Q_PROPERTY(int     id       READ id       CONSTANT)
    Q_PROPERTY(QString output   READ output   NOTIFY outputChanged)
    Q_PROPERTY(bool    active   READ active   NOTIFY activeChanged)   // currently running
    Q_PROPERTY(bool    complete READ complete NOTIFY completeChanged) // reached a terminal state

public:
    enum Priority {
        Interactive = 0,   // user-initiated — preempts Background, jumps the queue
        Background  = 10   // pollers — coalesced, yields to Interactive
    };
    Q_ENUM(Priority)

    int         id()       const { return _id; }
    QString     output()   const { return _output; }
    bool        active()   const { return _active; }
    bool        complete() const { return _complete; }
    QStringList args()     const { return _args; }
    Priority    priority() const { return _priority; }

signals:
    void outputChanged();
    void activeChanged();
    void completeChanged();
    void succeeded(int exitCode);          // exit 0
    void failed(const QString& errorText); // non-zero exit, crash, or start failure

private:
    friend class PXLABSCommandBus;

    explicit PXLABSRequest(int id, QStringList args, Priority priority, QObject* parent)
        : QObject(parent), _id(id), _args(std::move(args)), _priority(priority) {}

    void _appendOutput(const QString& text) { _output += text; emit outputChanged(); }
    void _setActive(bool a)   { if (_active   != a) { _active   = a; emit activeChanged();   } }
    void _setComplete(bool c) { if (_complete != c) { _complete = c; emit completeChanged(); } }

    const int         _id;
    const QStringList  _args;
    const Priority     _priority;
    QString            _output;
    bool               _active   = false;
    bool               _complete = false;
};

// ---------------------------------------------------------------------------
// PXLABSCommandBus — owns the single QProcess and the request queue.
class PXLABSCommandBus : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool    busy       READ busy       NOTIFY busyChanged)
    Q_PROPERTY(QString cliPath    READ cliPath    NOTIFY cliPathChanged)
    Q_PROPERTY(QString pythonPath READ pythonPath NOTIFY pythonPathChanged)

public:
    explicit PXLABSCommandBus(QObject* parent = nullptr);
    ~PXLABSCommandBus() override;

    // Enqueue a command. Never rejects. Returns a request owned by C++ (QML must
    // not delete it); the bus deletes it a short time after it completes.
    PXLABSRequest* enqueue(const QStringList& args,
                           PXLABSRequest::Priority priority = PXLABSRequest::Interactive);

    bool busy() const { return _current != nullptr; }

    // Settings — shared QSettings keys with the legacy PXLABSCommandRunner so
    // the existing PXLABS Settings panel keeps configuring both.
    QString cliPath() const;
    QString pythonPath() const;
    void    setCliPath(const QString& path);
    void    setPythonPath(const QString& path);

signals:
    void busyChanged();
    void cliPathChanged();
    void pythonPathChanged();

private slots:
    void _onStdOut();
    void _onStdErr();
    void _onFinished(int exitCode, QProcess::ExitStatus status);
    void _onError(QProcess::ProcessError error);

private:
    void _insertByPriority(PXLABSRequest* req);
    void _startRequest(PXLABSRequest* req);
    void _finishCurrent(bool ok, const QString& errorText);
    void _maybeStartNext();

    QProcess*             _process = nullptr;
    PXLABSRequest*        _current = nullptr;
    QList<PXLABSRequest*> _queue;
    int                   _nextId  = 1;
    // While preempting a Background poll we kill its process; suppress its
    // failure signal so the aborted poll is silent, not an error to the user.
    bool                  _suppressCurrentFailure = false;
};
