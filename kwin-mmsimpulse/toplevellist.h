#pragma once

#include <QList>
#include <QObject>

struct wl_client;
struct wl_global;
struct wl_resource;

namespace KWin
{
class Window;
}

// ext_foreign_toplevel_list_v1: the read-only window list, with an identifier
// per window that other protocols (window capture) name a window by.
class ToplevelList : public QObject
{
public:
    ToplevelList();
    ~ToplevelList() override;

    struct Handle;
    struct List;

    // The window an ext_foreign_toplevel_handle_v1 stands for, or null once it
    // is gone.
    static KWin::Window *window(wl_resource *handle);

    void forget(List *list);

private:
    static void bind(wl_client *client, void *data, uint32_t version, uint32_t id);
    void track(KWin::Window *window);
    void remove(KWin::Window *window);
    void sync(List *list, KWin::Window *window);
    void update(KWin::Window *window);

    wl_global *m_global = nullptr;
    QList<List *> m_lists;
};
