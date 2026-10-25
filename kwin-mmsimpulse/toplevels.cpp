#include "toplevels.h"
#include "outputs.h"

#include "wlr-foreign-toplevel-management-unstable-v1-server-protocol.h"

#include <window.h>
#include <workspace.h>

#include <QHash>

using namespace KWin;

static constexpr uint32_t s_version = 3;

struct ForeignToplevels::Handle
{
    wl_resource *resource = nullptr;
    Manager *manager = nullptr;
    // Null once the window is gone: requests on the handle then do nothing.
    Window *window = nullptr;
    bool sent = false;
    QString title;
    QString appId;
    QList<uint32_t> state;
    QSet<wl_resource *> outputs;
};

struct ForeignToplevels::Manager
{
    // Null after the client stopped the manager or went away. The handles it
    // already has still get their updates until they are destroyed.
    wl_resource *resource = nullptr;
    wl_client *client = nullptr;
    ForeignToplevels *self = nullptr;
    // A null value is a handle the client destroyed while its window was still
    // there: that window is not announced to this manager again.
    QHash<Window *, Handle *> handles;
};

// The windows a task bar lists: an application's own windows, not its
// dialogs, and not the shell's panels.
static bool listed(Window *w)
{
    return w->isClient() && !w->isDeleted() && w->isNormalWindow() && !w->skipTaskbar();
}

static QString appIdOf(Window *w)
{
    // The desktop file name is what launchers and icon lookups match on; X11
    // windows without one still have a class.
    return w->desktopFileName().isEmpty() ? w->resourceClass() : w->desktopFileName();
}

static QList<uint32_t> stateOf(Window *w)
{
    QList<uint32_t> state;
    if (w->maximizeMode() == MaximizeFull)
        state << ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED;
    if (w->isMinimized())
        state << ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED;
    if (w->isActive())
        state << ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED;
    if (w->isFullScreen())
        state << ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN;
    return state;
}

static ForeignToplevels::Handle *handleOf(wl_resource *resource)
{
    return static_cast<ForeignToplevels::Handle *>(wl_resource_get_user_data(resource));
}

static Window *windowOf(wl_resource *resource)
{
    return handleOf(resource)->window;
}

static const struct zwlr_foreign_toplevel_handle_v1_interface s_handleImpl = {
    .set_maximized = [](wl_client *, wl_resource *r) {
        if (Window *w = windowOf(r); w && w->isMaximizable())
            w->setMaximize(true, true);
    },
    .unset_maximized = [](wl_client *, wl_resource *r) {
        if (Window *w = windowOf(r); w && w->isMaximizable())
            w->setMaximize(false, false);
    },
    .set_minimized = [](wl_client *, wl_resource *r) {
        if (Window *w = windowOf(r); w && w->isMinimizable())
            w->setMinimized(true);
    },
    .unset_minimized = [](wl_client *, wl_resource *r) {
        if (Window *w = windowOf(r))
            w->setMinimized(false);
    },
    .activate = [](wl_client *, wl_resource *r, wl_resource *) {
        if (Window *w = windowOf(r))
            workspace()->activateWindow(w, true);
    },
    .close = [](wl_client *, wl_resource *r) {
        if (Window *w = windowOf(r); w && w->isCloseable())
            w->closeWindow();
    },
    // Where the task bar draws the window, for a minimise animation.
    .set_rectangle = [](wl_client *, wl_resource *, wl_resource *, int32_t, int32_t, int32_t, int32_t) {},
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
    // The requested output is not honoured: the window goes fullscreen where it is.
    .set_fullscreen = [](wl_client *, wl_resource *r, wl_resource *) {
        if (Window *w = windowOf(r); w && w->isFullScreenable())
            w->setFullScreen(true);
    },
    .unset_fullscreen = [](wl_client *, wl_resource *r) {
        if (Window *w = windowOf(r))
            w->setFullScreen(false);
    },
};

// Frees a manager that no client object refers to any more.
static void release(ForeignToplevels::Manager *m)
{
    if (m->resource)
        return;
    for (auto *h : std::as_const(m->handles)) {
        if (h)
            return;
    }
    if (m->self)
        m->self->forget(m);
    delete m;
}

static void handleDestroyed(wl_resource *resource)
{
    auto *h = handleOf(resource);
    auto *m = h->manager;
    if (h->window)
        m->handles[h->window] = nullptr;
    delete h;
    release(m);
}

static const struct zwlr_foreign_toplevel_manager_v1_interface s_managerImpl = {
    .stop = [](wl_client *, wl_resource *r) {
        zwlr_foreign_toplevel_manager_v1_send_finished(r);
        wl_resource_destroy(r);
    },
};

static void managerDestroyed(wl_resource *resource)
{
    auto *m = static_cast<ForeignToplevels::Manager *>(wl_resource_get_user_data(resource));
    m->resource = nullptr;
    release(m);
}

ForeignToplevels::ForeignToplevels()
{
    m_global = wl_global_create(*waylandServer()->display(), &zwlr_foreign_toplevel_manager_v1_interface,
                                s_version, this, bind);

    for (Window *w : workspace()->windows())
        track(w);
    connect(workspace(), &Workspace::windowAdded, this, [this](Window *w) {
        track(w);
        update(w);
    });
    connect(workspace(), &Workspace::windowRemoved, this, &ForeignToplevels::remove);
    mms::watchOutputs(this, [this] {
        updateAll();
    });
}

ForeignToplevels::~ForeignToplevels()
{
    wl_global_destroy(m_global);
    for (Manager *m : std::as_const(m_managers))
        m->self = nullptr;
}

void ForeignToplevels::forget(Manager *manager)
{
    m_managers.removeOne(manager);
}

void ForeignToplevels::bind(wl_client *client, void *data, uint32_t version, uint32_t id)
{
    auto *self = static_cast<ForeignToplevels *>(data);
    auto *m = new Manager;
    m->client = client;
    m->self = self;
    m->resource = wl_resource_create(client, &zwlr_foreign_toplevel_manager_v1_interface, version, id);
    wl_resource_set_implementation(m->resource, &s_managerImpl, m, managerDestroyed);
    self->m_managers << m;
    for (Window *w : workspace()->windows())
        self->sync(m, w);
}

void ForeignToplevels::track(Window *w)
{
    const auto changed = [this, w] {
        update(w);
    };
    connect(w, &Window::captionChanged, this, changed);
    connect(w, &Window::desktopFileNameChanged, this, changed);
    connect(w, &Window::windowClassChanged, this, changed);
    connect(w, &Window::maximizedChanged, this, changed);
    connect(w, &Window::minimizedChanged, this, changed);
    connect(w, &Window::activeChanged, this, changed);
    connect(w, &Window::fullScreenChanged, this, changed);
    connect(w, &Window::outputChanged, this, changed);
    connect(w, &Window::skipTaskbarChanged, this, changed);
}

void ForeignToplevels::update(Window *w)
{
    for (Manager *m : std::as_const(m_managers))
        sync(m, w);
}

void ForeignToplevels::updateAll()
{
    for (Window *w : workspace()->windows())
        update(w);
}

void ForeignToplevels::remove(Window *w)
{
    // A closing window lives on for its close animation and can still change.
    disconnect(w, nullptr, this, nullptr);
    for (Manager *m : std::as_const(m_managers)) {
        Handle *h = m->handles.take(w);
        if (!h)
            continue;
        h->window = nullptr;
        zwlr_foreign_toplevel_handle_v1_send_closed(h->resource);
    }
}

void ForeignToplevels::sync(Manager *m, Window *w)
{
    const bool known = m->handles.contains(w);
    Handle *h = m->handles.value(w);
    if (!listed(w)) {
        if (h) {
            m->handles.remove(w);
            h->window = nullptr;
            zwlr_foreign_toplevel_handle_v1_send_closed(h->resource);
        }
        return;
    }
    if (!h) {
        // Destroyed by the client, or a manager that no longer takes new windows.
        if (known || !m->resource)
            return;
        h = new Handle;
        h->manager = m;
        h->window = w;
        h->resource = wl_resource_create(m->client, &zwlr_foreign_toplevel_handle_v1_interface,
                                         wl_resource_get_version(m->resource), 0);
        wl_resource_set_implementation(h->resource, &s_handleImpl, h, handleDestroyed);
        m->handles.insert(w, h);
        zwlr_foreign_toplevel_manager_v1_send_toplevel(m->resource, h->resource);
    }

    bool changed = !h->sent;
    const QString title = w->caption();
    if (!h->sent || title != h->title) {
        h->title = title;
        zwlr_foreign_toplevel_handle_v1_send_title(h->resource, title.toUtf8().constData());
        changed = true;
    }
    const QString appId = appIdOf(w);
    if (!h->sent || appId != h->appId) {
        h->appId = appId;
        zwlr_foreign_toplevel_handle_v1_send_app_id(h->resource, appId.toUtf8().constData());
        changed = true;
    }
    const QList<uint32_t> state = stateOf(w);
    if (!h->sent || state != h->state) {
        h->state = state;
        wl_array array;
        wl_array_init(&array);
        for (uint32_t s : state)
            *static_cast<uint32_t *>(wl_array_add(&array, sizeof(uint32_t))) = s;
        zwlr_foreign_toplevel_handle_v1_send_state(h->resource, &array);
        wl_array_release(&array);
        changed = true;
    }
    const QSet<wl_resource *> outputs = mms::outputResources(w->output(), m->client);
    const QSet<wl_resource *> live = mms::liveOutputResources(m->client);
    for (wl_resource *o : std::as_const(h->outputs)) {
        if (!outputs.contains(o) && live.contains(o)) {
            zwlr_foreign_toplevel_handle_v1_send_output_leave(h->resource, o);
            changed = true;
        }
    }
    for (wl_resource *o : outputs) {
        if (!h->outputs.contains(o)) {
            zwlr_foreign_toplevel_handle_v1_send_output_enter(h->resource, o);
            changed = true;
        }
    }
    h->outputs = outputs;
    h->sent = true;
    if (changed)
        zwlr_foreign_toplevel_handle_v1_send_done(h->resource);
}
