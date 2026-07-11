// PXLABS integration — additive file, do not modify existing QGC code

#include "PXLABSCommandBus.h"

#include <QCoreApplication>
#include <QDir>
#include <QQmlEngine>
#include <QSettings>
#include <QTimer>

// Same QSettings keys as PXLABSCommandRunner so both read one configuration.
static constexpr char kCliPathKey[]    = "PXLABS/cliPath";
static constexpr char kPythonPathKey[] = "PXLABS/pythonPath";

// How long a completed request stays alive so QML signal handlers (which run
// synchronously during emit) and any late property reads still see it.
static constexpr int kRequestLingerMs = 2000;

// ---------------------------------------------------------------------------

PXLABSCommandBus::PXLABSCommandBus(QObject* parent)
    : QObject(parent)
    , _process(new QProcess(this))
{
    connect(_process, &QProcess::readyReadStandardOutput, this, &PXLABSCommandBus::_onStdOut);
    connect(_process, &QProcess::readyReadStandardError,  this, &PXLABSCommandBus::_onStdErr);
    connect(_process, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &PXLABSCommandBus::_onFinished);
    connect(_process, &QProcess::errorOccurred, this, &PXLABSCommandBus::_onError);
}

PXLABSCommandBus::~PXLABSCommandBus()
{
    if (_process->state() != QProcess::NotRunning) {
        _process->kill();
        _process->waitForFinished(2000);
    }
}

// ---------------------------------------------------------------------------
// Settings

QString PXLABSCommandBus::cliPath() const
{
    QSettings s;
    QString defaultPath = QDir(QCoreApplication::applicationDirPath()).filePath("tools/pxlabs_cli.exe");
    return s.value(kCliPathKey, defaultPath).toString();
}

QString PXLABSCommandBus::pythonPath() const
{
    QSettings s;
    return s.value(kPythonPathKey, QStringLiteral("python")).toString();
}

void PXLABSCommandBus::setCliPath(const QString& path)
{
    QSettings s;
    s.setValue(kCliPathKey, path);
    emit cliPathChanged();
}

void PXLABSCommandBus::setPythonPath(const QString& path)
{
    QSettings s;
    s.setValue(kPythonPathKey, path);
    emit pythonPathChanged();
}

// ---------------------------------------------------------------------------
// Enqueue

PXLABSRequest* PXLABSCommandBus::enqueue(const QStringList& args, PXLABSRequest::Priority priority)
{
    // Coalesce duplicate Background polls: if the same poll is already pending
    // (or currently running), reuse it instead of stacking redundant work.
    if (priority == PXLABSRequest::Background) {
        for (PXLABSRequest* r : _queue) {
            if (r->priority() == PXLABSRequest::Background && r->args() == args) {
                return r;
            }
        }
        if (_current && _current->priority() == PXLABSRequest::Background && _current->args() == args) {
            return _current;
        }
    }

    auto* req = new PXLABSRequest(_nextId++, args, priority, this);
    // C++ owns the request; QML only borrows it. Prevents the JS engine from
    // garbage-collecting or taking ownership of a returned QObject*.
    QQmlEngine::setObjectOwnership(req, QQmlEngine::CppOwnership);

    if (!_current) {
        _startRequest(req);
        return req;
    }

    // An Interactive request preempts a running Background poll — kill it now,
    // put ours at the front, and it starts as soon as the kill is reaped.
    if (priority == PXLABSRequest::Interactive &&
        _current->priority() == PXLABSRequest::Background) {
        _queue.prepend(req);
        _suppressCurrentFailure = true;
        _process->kill();   // _onFinished → _finishCurrent(silent) → _maybeStartNext()
        return req;
    }

    _insertByPriority(req);
    return req;
}

// Insert keeping Interactive ahead of Background, FIFO within each class.
void PXLABSCommandBus::_insertByPriority(PXLABSRequest* req)
{
    for (int i = 0; i < _queue.size(); ++i) {
        if (_queue.at(i)->priority() > req->priority()) {
            _queue.insert(i, req);
            return;
        }
    }
    _queue.append(req);
}

// ---------------------------------------------------------------------------
// Process lifecycle

void PXLABSCommandBus::_startRequest(PXLABSRequest* req)
{
    _current = req;
    req->_setActive(true);

    // If cliPath is a native executable (.exe), run it directly; otherwise
    // invoke via the python interpreter (dev workflow with the .py script).
    // Arguments go through as a QStringList — no shell, no space-splitting.
    const QString cli = cliPath();
    if (cli.endsWith(QLatin1String(".exe"), Qt::CaseInsensitive)) {
        _process->setProgram(cli);
        _process->setArguments(req->args());
    } else {
        QStringList argList;
        argList << cli;
        argList.append(req->args());
        _process->setProgram(pythonPath());
        _process->setArguments(argList);
    }
    _process->start();
    emit busyChanged();
}

void PXLABSCommandBus::_finishCurrent(bool ok, const QString& errorText)
{
    if (!_current) {
        return;
    }
    PXLABSRequest* req = _current;
    _current = nullptr;

    const bool suppress = _suppressCurrentFailure;
    _suppressCurrentFailure = false;

    req->_setActive(false);
    req->_setComplete(true);
    if (ok) {
        emit req->succeeded(0);
    } else if (!suppress) {
        emit req->failed(errorText);
    }

    // Let handlers run, then reap the request after a short linger.
    QTimer::singleShot(kRequestLingerMs, req, [req]() { req->deleteLater(); });

    emit busyChanged();
}

void PXLABSCommandBus::_maybeStartNext()
{
    if (_current || _queue.isEmpty()) {
        return;
    }
    _startRequest(_queue.takeFirst());
}

void PXLABSCommandBus::_onFinished(int exitCode, QProcess::ExitStatus status)
{
    // Drain any buffered output before signalling completion.
    if (_current) {
        const QByteArray remainOut = _process->readAllStandardOutput();
        if (!remainOut.isEmpty()) {
            _current->_appendOutput(QString::fromUtf8(remainOut));
        }
        const QByteArray remainErr = _process->readAllStandardError();
        if (!remainErr.isEmpty()) {
            _current->_appendOutput(QString::fromUtf8(remainErr));
        }
    }

    const bool ok = (status == QProcess::NormalExit && exitCode == 0);
    QString err;
    if (status != QProcess::NormalExit) {
        err = QStringLiteral("Process crashed or was killed.");
    } else if (exitCode != 0) {
        err = QStringLiteral("Command failed (exit %1).").arg(exitCode);
    }

    _finishCurrent(ok, err);
    _maybeStartNext();
}

void PXLABSCommandBus::_onError(QProcess::ProcessError error)
{
    // QProcess::finished may not fire on FailedToStart, so terminate here too.
    if (error == QProcess::FailedToStart) {
        _finishCurrent(false, QStringLiteral("Failed to start — check CLI path in PXLABS Settings."));
        _maybeStartNext();
    }
    // Other errors (Crashed/Timedout) arrive alongside finished(); handled there.
}

void PXLABSCommandBus::_onStdOut()
{
    if (_current) {
        _current->_appendOutput(QString::fromUtf8(_process->readAllStandardOutput()));
    }
}

void PXLABSCommandBus::_onStdErr()
{
    if (_current) {
        _current->_appendOutput(QString::fromUtf8(_process->readAllStandardError()));
    }
}
