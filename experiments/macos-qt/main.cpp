// The macOS spike: a plain Qt app that shows appring's own ring (the QML in
// ../../appring, unchanged) in a borderless, transparent, always-on-top window,
// with stand-ins for the few Quickshell pieces those files use (shim/).
#include <QCursor>
#include <QDir>
#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQuickImageProvider>
#include <QQuickWindow>
#include <QtQml>

// Quickshell.env() and the cursor's place, for the stand-ins and the spike.
class SpikeEnv : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString shellDir MEMBER shellDir CONSTANT)
public:
    QString shellDir;
    Q_INVOKABLE QVariant env(const QString &name) const {
        const QByteArray v = qgetenv(name.toUtf8());
        return v.isNull() ? QVariant() : QVariant(QString::fromUtf8(v));
    }
    Q_INVOKABLE QPoint cursor() const { return QCursor::pos(); }
};

// image://icon/NAME: an icon by name from the bundled theme.
class IconProvider : public QQuickImageProvider {
public:
    IconProvider() : QQuickImageProvider(QQuickImageProvider::Pixmap) {}
    QPixmap requestPixmap(const QString &id, QSize *size, const QSize &requested) override {
        const int side = requested.width() > 0 ? requested.width() : 128;
        QPixmap p = QIcon::fromTheme(id).pixmap(side, side);
        if (size) *size = p.size();
        return p;
    }
};

int main(int argc, char **argv) {
    QQuickWindow::setDefaultAlphaBuffer(true);
    QGuiApplication app(argc, argv);
    const QString share = QDir(QCoreApplication::applicationDirPath()).absoluteFilePath(SPIKE_SHARE);
    QIcon::setThemeSearchPaths({SPIKE_ICONS});
    QIcon::setThemeName("Papirus-Dark");

    auto *env = new SpikeEnv;
    env->shellDir = share + "/appring";
    qmlRegisterSingletonInstance("SpikeHelper", 1, 0, "SpikeEnv", env);

    QQmlApplicationEngine engine;
    engine.addImportPath(share + "/shim");
    engine.addImportPath(share);
    engine.addImageProvider("icon", new IconProvider);
    engine.load(QUrl::fromLocalFile(share + "/Spike.qml"));
    if (engine.rootObjects().isEmpty())
        return 1;
    return app.exec();
}

#include "main.moc"
