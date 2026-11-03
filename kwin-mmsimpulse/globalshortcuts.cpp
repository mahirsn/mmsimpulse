#include "globalshortcuts.h"

#include "hyprland-global-shortcuts-v1-server-protocol.h"

#include <wayland/display.h>
#include <wayland_server.h>

#include <KGlobalAccel>

#include <QAction>
#include <QDBusConnection>

#include <time.h>

using namespace KWin;

namespace
{

struct Shortcut
{
    GlobalShortcuts *owner;
    QString key;
    QAction *action;
};

void send(wl_resource *r, bool pressed)
{
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    const quint64 sec = ts.tv_sec;
    if (pressed)
        hyprland_global_shortcut_v1_send_pressed(r, sec >> 32, sec & 0xffffffff, ts.tv_nsec);
    else
        hyprland_global_shortcut_v1_send_released(r, sec >> 32, sec & 0xffffffff, ts.tv_nsec);
}

const struct hyprland_global_shortcut_v1_interface s_shortcutImpl = {
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

void registerShortcut(wl_client *client, wl_resource *manager, uint32_t id, const char *name, const char *appId,
                      const char *description, const char *)
{
    auto *owner = static_cast<GlobalShortcuts *>(wl_resource_get_user_data(manager));
    const QString key = QString::fromUtf8(appId) + QLatin1Char('\x1f') + QString::fromUtf8(name);
    if (owner->taken.contains(key)) {
        wl_resource_post_error(manager, HYPRLAND_GLOBAL_SHORTCUTS_MANAGER_V1_ERROR_ALREADY_TAKEN,
                               "%s:%s is taken", appId, name);
        return;
    }
    wl_resource *r = wl_resource_create(client, &hyprland_global_shortcut_v1_interface, wl_resource_get_version(manager), id);

    // The daemon keys actions by component (the app id) and name, and keeps
    // the keys bound to them across sessions; a new action starts with none.
    auto *action = new QAction(owner);
    action->setObjectName(QString::fromUtf8(name));
    action->setText(QString::fromUtf8(*description ? description : name));
    action->setProperty("componentName", QString::fromUtf8(appId));
    action->setProperty("componentDisplayName", QString::fromUtf8(appId));
    KGlobalAccel::self()->setDefaultShortcut(action, {});
    KGlobalAccel::self()->setShortcut(action, {}, KGlobalAccel::Autoloading);
    QObject::connect(KGlobalAccel::self(), &KGlobalAccel::globalShortcutActiveChanged, action, [action, r](QAction *a, bool active) {
        if (a == action)
            send(r, active);
    });
    owner->resources.insert(key, r);
    owner->taken.insert(key, action);

    wl_resource_set_implementation(r, &s_shortcutImpl, new Shortcut{owner, key, action}, [](wl_resource *r) {
        auto *s = static_cast<Shortcut *>(wl_resource_get_user_data(r));
        s->owner->taken.remove(s->key);
        s->owner->resources.remove(s->key);
        // Deleting the action lets the daemon forget it is present but keeps
        // its keys; removeAllShortcuts() would drop those too.
        delete s->action;
        delete s;
    });
}

const struct hyprland_global_shortcuts_manager_v1_interface s_managerImpl = {
    .register_shortcut = registerShortcut,
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

} // namespace

bool GlobalShortcuts::Trigger(const QString &appId, const QString &id)
{
    wl_resource *r = resources.value(appId + QLatin1Char('\x1f') + id);
    if (!r)
        return false;
    send(r, true);
    send(r, false);
    return true;
}

GlobalShortcuts::GlobalShortcuts()
{
    // Hyprland's `dispatch global app:id` (the bridge) presses an action
    // without a key; the daemon's invokeShortcut would only press it.
    QDBusConnection::sessionBus().registerObject(QStringLiteral("/MmsimpulseGlobalShortcuts"), this,
                                                 QDBusConnection::ExportScriptableSlots);
    m_global = wl_global_create(*waylandServer()->display(), &hyprland_global_shortcuts_manager_v1_interface, 1, this,
                                [](wl_client *client, void *data, uint32_t version, uint32_t id) {
                                    wl_resource *r = wl_resource_create(client, &hyprland_global_shortcuts_manager_v1_interface, version, id);
                                    wl_resource_set_implementation(r, &s_managerImpl, data, nullptr);
                                });
}

GlobalShortcuts::~GlobalShortcuts()
{
    wl_global_destroy(m_global);
}
