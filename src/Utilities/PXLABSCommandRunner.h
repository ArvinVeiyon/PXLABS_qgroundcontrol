// PXLABS integration — additive file, do not modify existing QGC code
// PXLABSCommandRunner: QProcess wrapper exposing pxlabs_cli.py to QML.

#pragma once

#include <QObject>
#include <QProcess>
#include <QString>

class PXLABSCommandRunner : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QString  lastOutput  READ lastOutput  NOTIFY outputReady)
    Q_PROPERTY(bool     running     READ running     NOTIFY runningChanged)
    Q_PROPERTY(QString  cliPath     READ cliPath     NOTIFY cliPathChanged)
    Q_PROPERTY(QString  pythonPath  READ pythonPath  NOTIFY pythonPathChanged)

public:
    explicit PXLABSCommandRunner(QObject* parent = nullptr);
    ~PXLABSCommandRunner() override;

    // Called from QML — pass everything after "python pxlabs_cli.py"
    Q_INVOKABLE void run(const QString& args);
    Q_INVOKABLE void abort();

    // Settings persisted in QSettings
    Q_INVOKABLE void setCliPath(const QString& path);
    Q_INVOKABLE void setPythonPath(const QString& path);

    QString lastOutput() const { return _lastOutput; }
    bool    running()    const { return _running; }
    QString cliPath()    const;
    QString pythonPath() const;

signals:
    void outputReady(const QString& text);
    void commandFinished(int exitCode);
    void commandFailed(const QString& errorText);
    void runningChanged();
    void cliPathChanged();
    void pythonPathChanged();

private slots:
    void _onStdOut();
    void _onStdErr();
    void _onFinished(int exitCode, QProcess::ExitStatus status);
    void _onError(QProcess::ProcessError error);

private:
    void _setRunning(bool r);

    QProcess* _process   = nullptr;
    QString   _lastOutput;
    bool      _running   = false;
};
