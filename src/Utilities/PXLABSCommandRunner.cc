// PXLABS integration — additive file, do not modify existing QGC code

#include "PXLABSCommandRunner.h"

#include <QCoreApplication>
#include <QDir>
#include <QSettings>

static constexpr char kCliPathKey[]    = "PXLABS/cliPath";
static constexpr char kPythonPathKey[] = "PXLABS/pythonPath";

// ---------------------------------------------------------------------------

PXLABSCommandRunner::PXLABSCommandRunner(QObject* parent)
    : QObject(parent)
    , _process(new QProcess(this))
{
    connect(_process, &QProcess::readyReadStandardOutput, this, &PXLABSCommandRunner::_onStdOut);
    connect(_process, &QProcess::readyReadStandardError,  this, &PXLABSCommandRunner::_onStdErr);
    connect(_process, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &PXLABSCommandRunner::_onFinished);
    connect(_process, &QProcess::errorOccurred, this, &PXLABSCommandRunner::_onError);
}

PXLABSCommandRunner::~PXLABSCommandRunner()
{
    if (_process->state() != QProcess::NotRunning) {
        _process->kill();
        _process->waitForFinished(2000);
    }
}

// ---------------------------------------------------------------------------
// Settings

QString PXLABSCommandRunner::cliPath() const
{
    QSettings s;
    QString defaultPath = QDir(QCoreApplication::applicationDirPath()).filePath("tools/pxlabs_cli.exe");
    return s.value(kCliPathKey, defaultPath).toString();
}

QString PXLABSCommandRunner::pythonPath() const
{
    QSettings s;
    return s.value(kPythonPathKey, QStringLiteral("python")).toString();
}

void PXLABSCommandRunner::setCliPath(const QString& path)
{
    QSettings s;
    s.setValue(kCliPathKey, path);
    emit cliPathChanged();
}

void PXLABSCommandRunner::setPythonPath(const QString& path)
{
    QSettings s;
    s.setValue(kPythonPathKey, path);
    emit pythonPathChanged();
}

// ---------------------------------------------------------------------------
// Run

void PXLABSCommandRunner::run(const QString& args)
{
    if (_running) {
        emit commandFailed(QStringLiteral("A command is already running — please wait or abort."));
        return;
    }

    _lastOutput.clear();
    _setRunning(true);

    // If cliPath is a native executable (.exe), run it directly.
    // Otherwise, invoke via python interpreter (dev workflow with .py script).
    const QString cli = cliPath();
    const QStringList extraArgs = args.split(QLatin1Char(' '), Qt::SkipEmptyParts);

    if (cli.endsWith(QLatin1String(".exe"), Qt::CaseInsensitive)) {
        _process->setProgram(cli);
        _process->setArguments(extraArgs);
    } else {
        QStringList argList;
        argList << cli;
        argList.append(extraArgs);
        _process->setProgram(pythonPath());
        _process->setArguments(argList);
    }
    _process->start();
}

void PXLABSCommandRunner::abort()
{
    if (_running) {
        _process->kill();
    }
}

// ---------------------------------------------------------------------------
// Private slots

void PXLABSCommandRunner::_onStdOut()
{
    _lastOutput += QString::fromUtf8(_process->readAllStandardOutput());
    emit outputReady(_lastOutput);
}

void PXLABSCommandRunner::_onStdErr()
{
    _lastOutput += QString::fromUtf8(_process->readAllStandardError());
    emit outputReady(_lastOutput);
}

void PXLABSCommandRunner::_onFinished(int exitCode, QProcess::ExitStatus status)
{
    // Drain any remaining buffered stdout/stderr before signalling completion,
    // otherwise outputReady fires after commandFinished and QML ignores it.
    const QByteArray remainOut = _process->readAllStandardOutput();
    if (!remainOut.isEmpty()) {
        _lastOutput += QString::fromUtf8(remainOut);
        emit outputReady(_lastOutput);
    }
    const QByteArray remainErr = _process->readAllStandardError();
    if (!remainErr.isEmpty()) {
        _lastOutput += QString::fromUtf8(remainErr);
        emit outputReady(_lastOutput);
    }

    _setRunning(false);
    if (status == QProcess::NormalExit) {
        emit commandFinished(exitCode);
    } else {
        emit commandFailed(QStringLiteral("Process crashed or was killed."));
    }
}

void PXLABSCommandRunner::_onError(QProcess::ProcessError error)
{
    _setRunning(false);
    QString msg;
    switch (error) {
    case QProcess::FailedToStart:
        msg = QStringLiteral("Failed to start — check CLI path in PXLABS Settings.");
        break;
    case QProcess::Crashed:
        msg = QStringLiteral("Process crashed.");
        break;
    case QProcess::Timedout:
        msg = QStringLiteral("Process timed out.");
        break;
    default:
        msg = QStringLiteral("Process error (%1).").arg(static_cast<int>(error));
        break;
    }
    emit commandFailed(msg);
}

// ---------------------------------------------------------------------------

void PXLABSCommandRunner::_setRunning(bool r)
{
    if (_running != r) {
        _running = r;
        emit runningChanged();
    }
}
