#pragma once

#include <QHash>
#include <QObject>

struct wl_global;

// hyprland_global_shortcuts_manager_v1: a client registers named actions
// (Quickshell's GlobalShortcut, so end4's and caelestia's keys) and is told
// when they are pressed and released. Each one becomes an action of KDE's
// global shortcut daemon, in a component named after the client's app id, so
// keys are bound to it as to any other: the user's config, System Settings,
// or Hyprland's `global, app:id` binds taken in with mms.source.
class GlobalShortcuts : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mmsimpulse.GlobalShortcuts")

public:
    GlobalShortcuts();
    ~GlobalShortcuts() override;

    // app id + "\x1f" + id of every shortcut a client holds now.
    QHash<QString, QObject *> taken;
    QHash<QString, struct wl_resource *> resources;

public Q_SLOTS:
    // Press and release the action app_id:id, as Hyprland's global dispatcher.
    Q_SCRIPTABLE bool Trigger(const QString &appId, const QString &id);

private:
    wl_global *m_global = nullptr;
};
