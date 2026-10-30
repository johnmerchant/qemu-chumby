// SPDX-License-Identifier: GPL-2.0-or-later
#include "glue.h"

#include <QApplication>
#include <QIcon>
#include <QImage>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QUrl>

namespace chumby {

static QString qstr(rust::Str s)
{
    return QString::fromUtf8(s.data(), static_cast<qsizetype>(s.size()));
}

int run_app(rust::Str app_id, rust::Str version)
{
    // Qt's own options come from the environment (QT_QPA_PLATFORM...);
    // ours were parsed in Rust.
    static int argc = 1;
    static char arg0[] = "chumby-desktop";
    static char *argv[] = {arg0, nullptr};

    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("chumby-desktop"));
    QApplication::setOrganizationName(QStringLiteral("qemu-chumby"));
    QApplication::setApplicationDisplayName(QStringLiteral("Chumby"));
    QApplication::setApplicationVersion(qstr(version));
    // Wayland's app id: the compositor finds the .desktop file, and its
    // icon, by this name.
    QGuiApplication::setDesktopFileName(qstr(app_id));
    QApplication::setWindowIcon(QIcon::fromTheme(
        qstr(app_id), QIcon(QStringLiteral(":/qt/qml/ChumbyDesktop/data/chumby-desktop.svg"))));

    // KDE Plasma's platform theme picks its own Qt Quick style
    // (org.kde.desktop); elsewhere Fusion, which follows the system's
    // palette and its light or dark scheme.
    if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE") && QQuickStyle::name().isEmpty())
        QQuickStyle::setStyle(QStringLiteral("Fusion"));

    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.load(QUrl(QStringLiteral("qrc:/qt/qml/ChumbyDesktop/qml/Main.qml")));
    if (engine.rootObjects().isEmpty())
        return 1;
    return app.exec();
}

static QQuickWindow *window()
{
    for (QWindow *w : QGuiApplication::topLevelWindows()) {
        if (auto *q = qobject_cast<QQuickWindow *>(w))
            return q;
    }
    return nullptr;
}

void send_key(int key, int modifiers, std::uint32_t scan_code, rust::Str text, bool press)
{
    QQuickWindow *w = window();
    if (!w)
        return;
    QKeyEvent ev(press ? QEvent::KeyPress : QEvent::KeyRelease, key,
                 Qt::KeyboardModifiers(modifiers), scan_code, 0, 0, qstr(text));
    QCoreApplication::sendEvent(w, &ev);
}

void send_mouse(double x, double y, int kind)
{
    QQuickWindow *w = window();
    if (!w)
        return;
    const QPointF local(x, y);
    const QEvent::Type type = kind == 0 ? QEvent::MouseButtonPress
                            : kind == 1 ? QEvent::MouseMove
                                        : QEvent::MouseButtonRelease;
    const Qt::MouseButton button = kind == 1 ? Qt::NoButton : Qt::LeftButton;
    const Qt::MouseButtons buttons = kind == 2 ? Qt::NoButton : Qt::LeftButton;
    QMouseEvent ev(type, local, local, w->mapToGlobal(local), button, buttons, Qt::NoModifier);
    QCoreApplication::sendEvent(w, &ev);
}

bool grab_window(rust::Str path)
{
    QQuickWindow *w = window();
    return w && w->grabWindow().save(qstr(path));
}

rust::String window_title()
{
    QQuickWindow *w = window();
    return rust::String(w ? w->title().toStdString() : std::string());
}

void quit_app()
{
    if (QQuickWindow *w = window())
        w->close();
    else
        QCoreApplication::quit();
}

} // namespace chumby
