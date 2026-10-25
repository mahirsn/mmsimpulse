#include "workspaces.h"
#include "outputs.h"

#include "ext-workspace-v1-server-protocol.h"

#include <options.h>
#include <virtualdesktops.h>
#include <workspace.h>

#include <functional>

using namespace KWin;

static constexpr uint32_t s_version = 1;

// A group or workspace object lives until both sides are done with it: the
// client destroys it (resource null), and this side removes it from its
// manager (detached). Whichever comes second frees it.
struct ExtWorkspaces::Group
{
    wl_resource *resource = nullptr;
    bool detached = false;
    QSet<wl_resource *> outputs;
};

struct ExtWorkspaces::Space
{
    wl_resource *resource = nullptr;
    bool detached = false;
    Manager *manager = nullptr;
    VirtualDesktop *desktop = nullptr;
    bool sent = false;
    QString name;
    QList<uint32_t> coordinates;
    uint32_t state = 0;
    bool inGroup = false;
    LogicalOutput *group = nullptr;
};

struct ExtWorkspaces::Manager
{
    wl_resource *resource = nullptr;
    wl_client *client = nullptr;
    ExtWorkspaces *self = nullptr;
    QHash<LogicalOutput *, Group *> groups;
    QHash<VirtualDesktop *, Space *> spaces;
    // Requests wait for commit, so a batch of them applies at once.
    QList<std::function<void()>> pending;
};

static void detach(ExtWorkspaces::Group *g)
{
    g->detached = true;
    if (!g->resource)
        delete g;
}

static void detach(ExtWorkspaces::Space *s)
{
    s->detached = true;
    s->manager = nullptr;
    if (!s->resource)
        delete s;
}

static const struct ext_workspace_group_handle_v1_interface s_groupImpl = {
    // No group offers create_workspace.
    .create_workspace = [](wl_client *, wl_resource *, const char *) {},
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

static void groupDestroyed(wl_resource *resource)
{
    auto *g = static_cast<ExtWorkspaces::Group *>(wl_resource_get_user_data(resource));
    g->resource = nullptr;
    if (g->detached)
        delete g;
}

static ExtWorkspaces::Space *spaceOf(wl_resource *resource)
{
    return static_cast<ExtWorkspaces::Space *>(wl_resource_get_user_data(resource));
}

static const struct ext_workspace_handle_v1_interface s_spaceImpl = {
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
    .activate = [](wl_client *, wl_resource *r) {
        auto *s = spaceOf(r);
        if (s->detached || !s->manager->self)
            return;
        ExtWorkspaces *self = s->manager->self;
        VirtualDesktop *desktop = s->desktop;
        s->manager->pending << [self, desktop] {
            self->activate(desktop);
        };
    },
    // Only activate is offered: a desktop is left by showing another one,
    // and desktops are added and removed in KWin's settings.
    .deactivate = [](wl_client *, wl_resource *) {},
    .assign = [](wl_client *, wl_resource *, wl_resource *) {},
    .remove = [](wl_client *, wl_resource *) {},
};

static void spaceDestroyed(wl_resource *resource)
{
    auto *s = spaceOf(resource);
    s->resource = nullptr;
    if (s->detached)
        delete s;
}

static const struct ext_workspace_manager_v1_interface s_managerImpl = {
    .commit = [](wl_client *, wl_resource *r) {
        auto *m = static_cast<ExtWorkspaces::Manager *>(wl_resource_get_user_data(r));
        const auto pending = std::exchange(m->pending, {});
        for (const auto &request : pending)
            request();
    },
    .stop = [](wl_client *, wl_resource *r) {
        ext_workspace_manager_v1_send_finished(r);
        wl_resource_destroy(r);
    },
};

static void managerDestroyed(wl_resource *resource)
{
    auto *m = static_cast<ExtWorkspaces::Manager *>(wl_resource_get_user_data(resource));
    for (auto *g : std::as_const(m->groups))
        detach(g);
    for (auto *s : std::as_const(m->spaces))
        detach(s);
    if (m->self)
        m->self->forget(m);
    delete m;
}

ExtWorkspaces::ExtWorkspaces()
{
    m_global = wl_global_create(*waylandServer()->display(), &ext_workspace_manager_v1_interface,
                                s_version, this, bind);

    VirtualDesktopManager *vdm = VirtualDesktopManager::self();
    for (VirtualDesktop *d : vdm->desktops())
        watchDesktop(d);
    connect(vdm, &VirtualDesktopManager::desktopAdded, this, [this](VirtualDesktop *d) {
        watchDesktop(d);
        refresh();
    });
    connect(vdm, &VirtualDesktopManager::desktopRemoved, this, &ExtWorkspaces::refresh);
    connect(vdm, &VirtualDesktopManager::currentChanged, this, &ExtWorkspaces::refresh);
    connect(options, &Options::perOutputVirtualDesktopsChanged, this, &ExtWorkspaces::refresh);
    mms::watchOutputs(this, [this] {
        refresh();
    });
}

ExtWorkspaces::~ExtWorkspaces()
{
    wl_global_destroy(m_global);
    for (Manager *m : std::as_const(m_managers))
        m->self = nullptr;
}

void ExtWorkspaces::forget(Manager *manager)
{
    m_managers.removeOne(manager);
}

void ExtWorkspaces::watchDesktop(VirtualDesktop *d)
{
    connect(d, &VirtualDesktop::nameChanged, this, &ExtWorkspaces::refresh);
    connect(d, &VirtualDesktop::x11DesktopNumberChanged, this, &ExtWorkspaces::refresh);
}

void ExtWorkspaces::activate(VirtualDesktop *desktop)
{
    VirtualDesktopManager *vdm = VirtualDesktopManager::self();
    if (!vdm->desktops().contains(desktop))
        return;
    if (!options->isPerOutputVirtualDesktops()) {
        vdm->setCurrent(desktop);
        return;
    }
    // On the monitor it belongs to: the one showing it, or the one that last did.
    LogicalOutput *output = m_home.value(desktop);
    if (!workspace()->outputs().contains(output))
        output = workspace()->activeOutput();
    vdm->setCurrent(desktop, output);
}

ExtWorkspaces::Model ExtWorkspaces::model()
{
    VirtualDesktopManager *vdm = VirtualDesktopManager::self();
    const QList<LogicalOutput *> outputs = workspace()->outputs();
    Model md;
    md.desktops = vdm->desktops();

    if (!options->isPerOutputVirtualDesktops()) {
        md.groups << nullptr;
        md.groupOutputs.insert(nullptr, outputs);
        for (VirtualDesktop *d : std::as_const(md.desktops))
            md.groupOf.insert(d, nullptr);
        if (VirtualDesktop *current = vdm->currentDesktop())
            md.active << current;
        return md;
    }

    for (LogicalOutput *o : outputs) {
        md.groups << o;
        md.groupOutputs.insert(o, {o});
        if (VirtualDesktop *d = vdm->currentDesktop(o)) {
            md.active << d;
            m_home.insert(d, o);
        }
    }
    for (auto it = m_home.begin(); it != m_home.end();) {
        if (md.desktops.contains(it.key()))
            ++it;
        else
            it = m_home.erase(it);
    }
    // A desktop no monitor has shown yet goes to the first one, so it can be
    // reached from a bar at all.
    for (VirtualDesktop *d : std::as_const(md.desktops)) {
        LogicalOutput *home = m_home.value(d);
        if (!outputs.contains(home)) {
            if (outputs.isEmpty())
                continue;
            home = outputs.first();
            m_home.insert(d, home);
        }
        md.groupOf.insert(d, home);
    }
    return md;
}

void ExtWorkspaces::refresh()
{
    m_model = model();
    for (Manager *m : std::as_const(m_managers))
        sync(m);
}

void ExtWorkspaces::bind(wl_client *client, void *data, uint32_t version, uint32_t id)
{
    auto *self = static_cast<ExtWorkspaces *>(data);
    auto *m = new Manager;
    m->client = client;
    m->self = self;
    m->resource = wl_resource_create(client, &ext_workspace_manager_v1_interface, version, id);
    wl_resource_set_implementation(m->resource, &s_managerImpl, m, managerDestroyed);
    self->m_managers << m;
    self->m_model = self->model();
    self->sync(m);
}

void ExtWorkspaces::sync(Manager *m)
{
    const Model &md = m_model;
    bool changed = false;

    for (LogicalOutput *key : md.groups) {
        if (m->groups.contains(key))
            continue;
        auto *g = new Group;
        g->resource = wl_resource_create(m->client, &ext_workspace_group_handle_v1_interface,
                                         wl_resource_get_version(m->resource), 0);
        wl_resource_set_implementation(g->resource, &s_groupImpl, g, groupDestroyed);
        m->groups.insert(key, g);
        ext_workspace_manager_v1_send_workspace_group(m->resource, g->resource);
        ext_workspace_group_handle_v1_send_capabilities(g->resource, 0);
        changed = true;
    }

    const QSet<wl_resource *> live = mms::liveOutputResources(m->client);
    for (auto it = m->groups.cbegin(); it != m->groups.cend(); ++it) {
        Group *g = it.value();
        if (!md.groups.contains(it.key()) || !g->resource)
            continue;
        QSet<wl_resource *> outputs;
        for (LogicalOutput *o : md.groupOutputs.value(it.key()))
            outputs.unite(mms::outputResources(o, m->client));
        for (wl_resource *o : std::as_const(g->outputs)) {
            if (!outputs.contains(o) && live.contains(o)) {
                ext_workspace_group_handle_v1_send_output_leave(g->resource, o);
                changed = true;
            }
        }
        for (wl_resource *o : std::as_const(outputs)) {
            if (!g->outputs.contains(o)) {
                ext_workspace_group_handle_v1_send_output_enter(g->resource, o);
                changed = true;
            }
        }
        g->outputs = outputs;
    }

    for (VirtualDesktop *d : md.desktops) {
        Space *s = m->spaces.value(d);
        if (!s) {
            s = new Space;
            s->manager = m;
            s->desktop = d;
            s->resource = wl_resource_create(m->client, &ext_workspace_handle_v1_interface,
                                             wl_resource_get_version(m->resource), 0);
            wl_resource_set_implementation(s->resource, &s_spaceImpl, s, spaceDestroyed);
            m->spaces.insert(d, s);
            ext_workspace_manager_v1_send_workspace(m->resource, s->resource);
            ext_workspace_handle_v1_send_id(s->resource, d->id().toUtf8().constData());
            ext_workspace_handle_v1_send_capabilities(s->resource, EXT_WORKSPACE_HANDLE_V1_WORKSPACE_CAPABILITIES_ACTIVATE);
            changed = true;
        }
        if (!s->resource)
            continue;
        if (!s->sent || d->name() != s->name) {
            s->name = d->name();
            ext_workspace_handle_v1_send_name(s->resource, s->name.toUtf8().constData());
            changed = true;
        }
        const QList<uint32_t> coordinates{d->x11DesktopNumber() - 1};
        if (!s->sent || coordinates != s->coordinates) {
            s->coordinates = coordinates;
            wl_array array;
            wl_array_init(&array);
            for (uint32_t c : coordinates)
                *static_cast<uint32_t *>(wl_array_add(&array, sizeof(uint32_t))) = c;
            ext_workspace_handle_v1_send_coordinates(s->resource, &array);
            wl_array_release(&array);
            changed = true;
        }
        const uint32_t state = md.active.contains(d) ? EXT_WORKSPACE_HANDLE_V1_STATE_ACTIVE : 0;
        if (!s->sent || state != s->state) {
            s->state = state;
            ext_workspace_handle_v1_send_state(s->resource, state);
            changed = true;
        }
        s->sent = true;
    }

    // Membership, once every group it can move to exists.
    for (VirtualDesktop *d : md.desktops) {
        Space *s = m->spaces.value(d);
        const bool wantIn = md.groupOf.contains(d);
        LogicalOutput *want = md.groupOf.value(d);
        if (s->inGroup && (!wantIn || s->group != want)) {
            Group *old = m->groups.value(s->group);
            if (old && old->resource && s->resource) {
                ext_workspace_group_handle_v1_send_workspace_leave(old->resource, s->resource);
                changed = true;
            }
            s->inGroup = false;
        }
        if (!s->inGroup && wantIn) {
            Group *g = m->groups.value(want);
            if (g && g->resource && s->resource) {
                ext_workspace_group_handle_v1_send_workspace_enter(g->resource, s->resource);
                changed = true;
            }
            s->inGroup = true;
            s->group = want;
        }
    }

    for (auto it = m->spaces.begin(); it != m->spaces.end();) {
        Space *s = it.value();
        if (md.desktops.contains(it.key())) {
            ++it;
            continue;
        }
        if (s->resource) {
            Group *g = s->inGroup ? m->groups.value(s->group) : nullptr;
            if (g && g->resource)
                ext_workspace_group_handle_v1_send_workspace_leave(g->resource, s->resource);
            ext_workspace_handle_v1_send_removed(s->resource);
            changed = true;
        }
        it = m->spaces.erase(it);
        detach(s);
    }

    for (auto it = m->groups.begin(); it != m->groups.end();) {
        Group *g = it.value();
        if (md.groups.contains(it.key())) {
            ++it;
            continue;
        }
        if (g->resource) {
            ext_workspace_group_handle_v1_send_removed(g->resource);
            changed = true;
        }
        it = m->groups.erase(it);
        detach(g);
    }

    if (changed)
        ext_workspace_manager_v1_send_done(m->resource);
}
