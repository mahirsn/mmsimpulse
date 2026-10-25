#pragma once

#include <QList>
#include <QObject>

struct wl_client;
struct wl_global;

namespace KWin
{
class Window;
}

// zwlr_foreign_toplevel_manager_v1: the window list a task bar or dock shows,
// and minimise, maximise, fullscreen, activate and close on its windows.
class ForeignToplevels : public QObject
{
public:
    ForeignToplevels();
    ~ForeignToplevels() override;

    struct Handle;
    struct Manager;

    void update(KWin::Window *window);
    void updateAll();
    void forget(Manager *manager);

private:
    static void bind(wl_client *client, void *data, uint32_t version, uint32_t id);
    void track(KWin::Window *window);
    void remove(KWin::Window *window);
    void sync(Manager *manager, KWin::Window *window);

    wl_global *m_global = nullptr;
    QList<Manager *> m_managers;
};
