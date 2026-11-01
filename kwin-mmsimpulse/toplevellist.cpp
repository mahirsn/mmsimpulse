#include "toplevellist.h"

#include "ext-foreign-toplevel-list-v1-server-protocol.h"

#include <wayland/display.h>
#include <wayland_server.h>
#include <window.h>
#include <workspace.h>

#include <QHash>

using namespace KWin;

static constexpr uint32_t s_version = 1;

struct ToplevelList::Handle
{
    wl_resource *resource = nullptr;
    List *list = nullptr;
    // Null once the window is gone; the handle is then inert.
    Window *window = nullptr;
    bool sent = false;
    QString title;
    QString appId;
};

struct ToplevelList::List
{
    // Null after the client destroyed the list. Handles it already has keep
    // their updates until they are destroyed.
    wl_resource *resource = nullptr;
    wl_client *client = nullptr;
    ToplevelList *self = nullptr;
    // After stop, no new windows are announced.
    bool stopped = false;
    // A null value is a handle the client destroyed while its window was there:
    // that window is not announced to this list again.
    QHash<Window *, Handle *> handles;
};

// The same windows a task bar lists in the other window-list protocol.
static bool listed(Window *w)
{
    return w->isClient() && !w->isDeleted() && w->isNormalWindow() && !w->skipTaskbar();
}

static QString appIdOf(Window *w)
{
    return w->desktopFileName().isEmpty() ? w->resourceClass() : w->desktopFileName();
}

static void release(ToplevelList::List *l)
{
    if (l->resource)
        return;
    for (auto *h : std::as_const(l->handles)) {
        if (h)
            return;
    }
    if (l->self)
        l->self->forget(l);
    delete l;
}

static const struct ext_foreign_toplevel_handle_v1_interface s_handleImpl = {
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

static void handleDestroyed(wl_resource *resource)
{
    auto *h = static_cast<ToplevelList::Handle *>(wl_resource_get_user_data(resource));
    auto *l = h->list;
    if (h->window)
        l->handles[h->window] = nullptr;
    delete h;
    release(l);
}

static const struct ext_foreign_toplevel_list_v1_interface s_listImpl = {
    .stop = [](wl_client *, wl_resource *r) {
        auto *l = static_cast<ToplevelList::List *>(wl_resource_get_user_data(r));
        if (l->stopped)
            return;
        l->stopped = true;
        ext_foreign_toplevel_list_v1_send_finished(r);
    },
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

static void listDestroyed(wl_resource *resource)
{
    auto *l = static_cast<ToplevelList::List *>(wl_resource_get_user_data(resource));
    l->resource = nullptr;
    l->stopped = true;
    release(l);
}

Window *ToplevelList::window(wl_resource *handle)
{
    if (!handle || !wl_resource_instance_of(handle, &ext_foreign_toplevel_handle_v1_interface, &s_handleImpl))
        return nullptr;
    return static_cast<Handle *>(wl_resource_get_user_data(handle))->window;
}

ToplevelList::ToplevelList()
{
    m_global = wl_global_create(*waylandServer()->display(), &ext_foreign_toplevel_list_v1_interface,
                                s_version, this, bind);
    for (Window *w : workspace()->windows())
        track(w);
    connect(workspace(), &Workspace::windowAdded, this, [this](Window *w) {
        track(w);
        update(w);
    });
    connect(workspace(), &Workspace::windowRemoved, this, &ToplevelList::remove);
}

ToplevelList::~ToplevelList()
{
    wl_global_destroy(m_global);
    for (List *l : std::as_const(m_lists))
        l->self = nullptr;
}

void ToplevelList::forget(List *list)
{
    m_lists.removeOne(list);
}

void ToplevelList::bind(wl_client *client, void *data, uint32_t version, uint32_t id)
{
    auto *self = static_cast<ToplevelList *>(data);
    auto *l = new List;
    l->client = client;
    l->self = self;
    l->resource = wl_resource_create(client, &ext_foreign_toplevel_list_v1_interface, version, id);
    wl_resource_set_implementation(l->resource, &s_listImpl, l, listDestroyed);
    self->m_lists << l;
    for (Window *w : workspace()->windows())
        self->sync(l, w);
}

void ToplevelList::track(Window *w)
{
    const auto changed = [this, w] {
        update(w);
    };
    connect(w, &Window::captionChanged, this, changed);
    connect(w, &Window::desktopFileNameChanged, this, changed);
    connect(w, &Window::windowClassChanged, this, changed);
    connect(w, &Window::skipTaskbarChanged, this, changed);
}

void ToplevelList::update(Window *w)
{
    for (List *l : std::as_const(m_lists))
        sync(l, w);
}

static void closeHandle(ToplevelList::Handle *h)
{
    h->window = nullptr;
    ext_foreign_toplevel_handle_v1_send_closed(h->resource);
}

void ToplevelList::remove(Window *w)
{
    disconnect(w, nullptr, this, nullptr);
    for (List *l : std::as_const(m_lists)) {
        if (Handle *h = l->handles.take(w))
            closeHandle(h);
    }
}

void ToplevelList::sync(List *l, Window *w)
{
    const bool known = l->handles.contains(w);
    Handle *h = l->handles.value(w);
    if (!listed(w)) {
        if (h) {
            l->handles.remove(w);
            closeHandle(h);
        }
        return;
    }
    if (!h) {
        if (known || l->stopped || !l->resource)
            return;
        h = new Handle;
        h->list = l;
        h->window = w;
        h->resource = wl_resource_create(l->client, &ext_foreign_toplevel_handle_v1_interface,
                                         wl_resource_get_version(l->resource), 0);
        wl_resource_set_implementation(h->resource, &s_handleImpl, h, handleDestroyed);
        l->handles.insert(w, h);
        ext_foreign_toplevel_list_v1_send_toplevel(l->resource, h->resource);
        // Unique among this compositor's windows and never reused.
        ext_foreign_toplevel_handle_v1_send_identifier(h->resource,
                                                       w->internalId().toString(QUuid::WithoutBraces).toUtf8().constData());
    }

    bool changed = !h->sent;
    const QString title = w->caption();
    if (!h->sent || title != h->title) {
        h->title = title;
        ext_foreign_toplevel_handle_v1_send_title(h->resource, title.toUtf8().constData());
        changed = true;
    }
    const QString appId = appIdOf(w);
    if (!h->sent || appId != h->appId) {
        h->appId = appId;
        ext_foreign_toplevel_handle_v1_send_app_id(h->resource, appId.toUtf8().constData());
        changed = true;
    }
    h->sent = true;
    if (changed)
        ext_foreign_toplevel_handle_v1_send_done(h->resource);
}
