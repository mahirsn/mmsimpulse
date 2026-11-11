#include "outputmanagement.h"

#include "wlr-output-management-unstable-v1-server-protocol.h"

#include <core/backendoutput.h>
#include <core/outputbackend.h>
#include <core/outputconfiguration.h>
#include <main.h>
#include <wayland/display.h>
#include <wayland_server.h>
#include <workspace.h>

#include <QHash>
#include <QPointer>
#include <QSet>
#include <QTimer>

using namespace KWin;

// 4 adds adaptive sync, which this does not offer.
static constexpr uint32_t s_version = 3;

struct OutputManagement::Head
{
    wl_resource *resource = nullptr;
    Manager *manager = nullptr;
    QPointer<BackendOutput> output;
    // The client's mode objects, by the mode they stand for.
    QHash<OutputMode *, wl_resource *> modes;
};

struct OutputManagement::Manager
{
    // Null once the client destroyed it or stopped it.
    wl_resource *resource = nullptr;
    wl_client *client = nullptr;
    OutputManagement *self = nullptr;
    bool stopped = false;
    // A null value is a head the client released while its output was there.
    QHash<BackendOutput *, Head *> heads;
};

namespace
{

QList<BackendOutput *> outputs()
{
    return kwinApp()->outputBackend()->outputs();
}

// A mode object holds on to the mode it stands for.
struct ModeRef
{
    std::shared_ptr<OutputMode> mode;
    OutputManagement::Head *head = nullptr;
};

const struct zwlr_output_mode_v1_interface s_modeImpl = {
    .release = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

void modeDestroyed(wl_resource *r)
{
    auto *ref = static_cast<ModeRef *>(wl_resource_get_user_data(r));
    if (ref->head)
        ref->head->modes.remove(ref->mode.get());
    delete ref;
}

ModeRef *modeOf(wl_resource *r)
{
    if (!r || !wl_resource_instance_of(r, &zwlr_output_mode_v1_interface, &s_modeImpl))
        return nullptr;
    return static_cast<ModeRef *>(wl_resource_get_user_data(r));
}

const struct zwlr_output_head_v1_interface s_headImpl = {
    .release = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

void headDestroyed(wl_resource *r)
{
    auto *h = static_cast<OutputManagement::Head *>(wl_resource_get_user_data(r));
    for (wl_resource *m : std::as_const(h->modes))
        static_cast<ModeRef *>(wl_resource_get_user_data(m))->head = nullptr;
    // By value, not by h->output: that is null already when the output went
    // before the manager's next sync, and the manager would keep this head.
    if (h->manager) {
        for (auto &head : h->manager->heads) {
            if (head == h)
                head = nullptr;
        }
    }
    delete h;
}

OutputManagement::Head *headOf(wl_resource *r)
{
    if (!r || !wl_resource_instance_of(r, &zwlr_output_head_v1_interface, &s_headImpl))
        return nullptr;
    return static_cast<OutputManagement::Head *>(wl_resource_get_user_data(r));
}

void finishHead(OutputManagement::Head *h)
{
    for (wl_resource *m : std::as_const(h->modes)) {
        static_cast<ModeRef *>(wl_resource_get_user_data(m))->head = nullptr;
        zwlr_output_mode_v1_send_finished(m);
    }
    h->modes.clear();
    h->manager = nullptr;
    zwlr_output_head_v1_send_finished(h->resource);
}

void sendModes(OutputManagement::Head *h, wl_client *client)
{
    BackendOutput *o = h->output;
    const auto modes = o->modes();
    QSet<OutputMode *> present;
    for (const auto &mode : modes)
        present.insert(mode.get());
    for (auto it = h->modes.begin(); it != h->modes.end();) {
        if (present.contains(it.key())) {
            ++it;
            continue;
        }
        static_cast<ModeRef *>(wl_resource_get_user_data(it.value()))->head = nullptr;
        zwlr_output_mode_v1_send_finished(it.value());
        it = h->modes.erase(it);
    }
    for (const auto &mode : modes) {
        if (h->modes.contains(mode.get()))
            continue;
        wl_resource *m = wl_resource_create(client, &zwlr_output_mode_v1_interface, wl_resource_get_version(h->resource), 0);
        wl_resource_set_implementation(m, &s_modeImpl, new ModeRef{mode, h}, modeDestroyed);
        h->modes.insert(mode.get(), m);
        zwlr_output_head_v1_send_mode(h->resource, m);
        zwlr_output_mode_v1_send_size(m, mode->size().width(), mode->size().height());
        zwlr_output_mode_v1_send_refresh(m, mode->refreshRate());
        if (mode->flags() & OutputModeline::Flag::Preferred)
            zwlr_output_mode_v1_send_preferred(m);
    }
}

void sendState(OutputManagement::Head *h)
{
    BackendOutput *o = h->output;
    zwlr_output_head_v1_send_enabled(h->resource, o->isEnabled());
    if (!o->isEnabled())
        return;
    if (wl_resource *m = h->modes.value(o->currentMode().get()))
        zwlr_output_head_v1_send_current_mode(h->resource, m);
    zwlr_output_head_v1_send_position(h->resource, o->position().x(), o->position().y());
    zwlr_output_head_v1_send_transform(h->resource, o->transform().kind());
    zwlr_output_head_v1_send_scale(h->resource, wl_fixed_from_double(o->scale()));
}

// ---------------------------------------------------------------------------
// Configurations
// ---------------------------------------------------------------------------

struct Configuration
{
    wl_resource *resource = nullptr;
    QPointer<OutputManagement> owner;
    OutputManagement::Manager *manager = nullptr;
    uint32_t serial = 0;
    bool used = false;
    // An output a configuration head names that went away meanwhile.
    bool invalid = false;
    OutputConfiguration config;
    QSet<BackendOutput *> configured;
    // Its heads outlive it when the client destroys it first.
    QList<struct ConfigHead *> heads;
};

struct ConfigHead
{
    Configuration *configuration = nullptr;
    QPointer<BackendOutput> output;
    QSet<int> set;
};

ConfigHead *configHeadOf(wl_resource *r)
{
    return static_cast<ConfigHead *>(wl_resource_get_user_data(r));
}

// The change set of a configuration head, or null after a request it already
// had, which is an error.
std::shared_ptr<OutputChangeSet> changes(wl_resource *r, int request)
{
    ConfigHead *c = configHeadOf(r);
    if (c->set.contains(request)) {
        wl_resource_post_error(r, ZWLR_OUTPUT_CONFIGURATION_HEAD_V1_ERROR_ALREADY_SET, "property already set");
        return nullptr;
    }
    c->set.insert(request);
    if (!c->configuration || !c->output) {
        if (c->configuration)
            c->configuration->invalid = true;
        return nullptr;
    }
    return c->configuration->config.changeSet(c->output);
}

enum Request {
    Mode,
    Position,
    Transform,
    Scale,
};

const struct zwlr_output_configuration_head_v1_interface s_configHeadImpl = {
    .set_mode = [](wl_client *, wl_resource *r, wl_resource *mode) {
        ModeRef *ref = modeOf(mode);
        ConfigHead *c = configHeadOf(r);
        if (ref && c->output && !c->output->modes().contains(ref->mode)) {
            wl_resource_post_error(r, ZWLR_OUTPUT_CONFIGURATION_HEAD_V1_ERROR_INVALID_MODE, "mode is not one of this head's");
            return;
        }
        if (auto set = changes(r, Mode); set && ref)
            set->currentMode = set->desiredMode = ref->mode->modeline();
    },
    // Only a mode the output has: KWin can generate others, but a client
    // asking by size and refresh means one of these.
    .set_custom_mode = [](wl_client *, wl_resource *r, int32_t width, int32_t height, int32_t refresh) {
        ConfigHead *c = configHeadOf(r);
        std::shared_ptr<OutputMode> found;
        if (c->output) {
            for (const auto &mode : c->output->modes()) {
                if (mode->size() != QSize(width, height))
                    continue;
                if (refresh <= 0 ? (!found || mode->refreshRate() > found->refreshRate())
                                 : std::abs(int64_t(mode->refreshRate()) - refresh) < 1000
                                       && (!found || std::abs(int64_t(mode->refreshRate()) - refresh) < std::abs(int64_t(found->refreshRate()) - refresh)))
                    found = mode;
            }
            if (!found) {
                wl_resource_post_error(r, ZWLR_OUTPUT_CONFIGURATION_HEAD_V1_ERROR_INVALID_CUSTOM_MODE, "no such mode");
                return;
            }
        }
        if (auto set = changes(r, Mode); set && found)
            set->currentMode = set->desiredMode = found->modeline();
    },
    .set_position = [](wl_client *, wl_resource *r, int32_t x, int32_t y) {
        if (auto set = changes(r, Position))
            set->pos = QPoint(x, y);
    },
    .set_transform = [](wl_client *, wl_resource *r, int32_t transform) {
        if (transform < WL_OUTPUT_TRANSFORM_NORMAL || transform > WL_OUTPUT_TRANSFORM_FLIPPED_270) {
            wl_resource_post_error(r, ZWLR_OUTPUT_CONFIGURATION_HEAD_V1_ERROR_INVALID_TRANSFORM, "invalid transform");
            return;
        }
        if (auto set = changes(r, Transform))
            set->transform = set->manualTransform = OutputTransform(OutputTransform::Kind(transform));
    },
    .set_scale = [](wl_client *, wl_resource *r, wl_fixed_t scale) {
        const double s = wl_fixed_to_double(scale);
        if (s <= 0) {
            wl_resource_post_error(r, ZWLR_OUTPUT_CONFIGURATION_HEAD_V1_ERROR_INVALID_SCALE, "invalid scale");
            return;
        }
        if (auto set = changes(r, Scale))
            set->scaleSetting = s;
    },
    .set_adaptive_sync = [](wl_client *, wl_resource *, uint32_t) {},
};

Configuration *configurationOf(wl_resource *r)
{
    return static_cast<Configuration *>(wl_resource_get_user_data(r));
}

// Whether the head is in this configuration, after marking it so; posts the
// error when it already was.
BackendOutput *configure(wl_resource *r, wl_resource *head)
{
    Configuration *c = configurationOf(r);
    OutputManagement::Head *h = headOf(head);
    BackendOutput *o = h ? h->output.data() : nullptr;
    if (!o) {
        c->invalid = true;
        return nullptr;
    }
    if (c->configured.contains(o)) {
        wl_resource_post_error(r, ZWLR_OUTPUT_CONFIGURATION_V1_ERROR_ALREADY_CONFIGURED_HEAD, "head already configured");
        return nullptr;
    }
    c->configured.insert(o);
    return o;
}

// Sends the result; true when the configuration is fit to be applied.
bool check(wl_resource *r)
{
    Configuration *c = configurationOf(r);
    if (c->used) {
        wl_resource_post_error(r, ZWLR_OUTPUT_CONFIGURATION_V1_ERROR_ALREADY_USED, "configuration already used");
        return false;
    }
    c->used = true;
    if (!c->owner || c->serial != c->owner->serial()) {
        zwlr_output_configuration_v1_send_cancelled(r);
        return false;
    }
    for (BackendOutput *o : outputs()) {
        if (!c->configured.contains(o)) {
            wl_resource_post_error(r, ZWLR_OUTPUT_CONFIGURATION_V1_ERROR_UNCONFIGURED_HEAD, "a head is not configured");
            return false;
        }
    }
    bool anyEnabled = false;
    for (BackendOutput *o : outputs()) {
        const auto set = c->config.constChangeSet(o);
        const bool enabled = set && set->enabled ? *set->enabled : o->isEnabled();
        anyEnabled |= enabled;
        // KWin turns down an enabled output at a negative position.
        if (enabled && set && set->pos && (set->pos->x() < 0 || set->pos->y() < 0))
            c->invalid = true;
    }
    if (c->invalid || !anyEnabled) {
        zwlr_output_configuration_v1_send_failed(r);
        return false;
    }
    return true;
}

const struct zwlr_output_configuration_v1_interface s_configImpl = {
    .enable_head = [](wl_client *client, wl_resource *r, uint32_t id, wl_resource *head) {
        auto *ch = new ConfigHead;
        wl_resource *res = wl_resource_create(client, &zwlr_output_configuration_head_v1_interface, wl_resource_get_version(r), id);
        wl_resource_set_implementation(res, &s_configHeadImpl, ch, [](wl_resource *res) {
            ConfigHead *head = configHeadOf(res);
            if (head->configuration)
                head->configuration->heads.removeOne(head);
            delete head;
        });
        if (BackendOutput *o = configure(r, head)) {
            ch->configuration = configurationOf(r);
            ch->configuration->heads << ch;
            ch->output = o;
            ch->configuration->config.changeSet(o)->enabled = true;
        }
    },
    .disable_head = [](wl_client *, wl_resource *r, wl_resource *head) {
        if (BackendOutput *o = configure(r, head))
            configurationOf(r)->config.changeSet(o)->enabled = false;
    },
    .apply = [](wl_client *, wl_resource *r) {
        if (!check(r))
            return;
        Configuration *c = configurationOf(r);
        c->config.source = OutputConfiguration::Source::User;
        if (workspace()->applyOutputConfiguration(c->config))
            zwlr_output_configuration_v1_send_succeeded(r);
        else
            zwlr_output_configuration_v1_send_failed(r);
    },
    .test = [](wl_client *, wl_resource *r) {
        if (check(r))
            zwlr_output_configuration_v1_send_succeeded(r);
    },
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

const struct zwlr_output_manager_v1_interface s_managerImpl = {
    .create_configuration = [](wl_client *client, wl_resource *r, uint32_t id, uint32_t serial) {
        auto *m = static_cast<OutputManagement::Manager *>(wl_resource_get_user_data(r));
        auto *c = new Configuration;
        c->owner = m->self;
        c->manager = m;
        c->serial = serial;
        c->resource = wl_resource_create(client, &zwlr_output_configuration_v1_interface, wl_resource_get_version(r), id);
        wl_resource_set_implementation(c->resource, &s_configImpl, c, [](wl_resource *res) {
            Configuration *c = configurationOf(res);
            for (ConfigHead *head : std::as_const(c->heads))
                head->configuration = nullptr;
            delete c;
        });
    },
    .stop = [](wl_client *, wl_resource *r) {
        auto *m = static_cast<OutputManagement::Manager *>(wl_resource_get_user_data(r));
        if (m->stopped)
            return;
        m->stopped = true;
        zwlr_output_manager_v1_send_finished(r);
        wl_resource_destroy(r);
    },
};

} // namespace

static void managerDestroyed(wl_resource *r)
{
    auto *m = static_cast<OutputManagement::Manager *>(wl_resource_get_user_data(r));
    if (m->self)
        m->self->forget(m);
    for (auto *h : std::as_const(m->heads)) {
        if (h)
            h->manager = nullptr;
    }
    delete m;
}

OutputManagement::OutputManagement()
{
    m_global = wl_global_create(*waylandServer()->display(), &zwlr_output_manager_v1_interface, s_version, this, bind);
    OutputBackend *backend = kwinApp()->outputBackend();
    for (BackendOutput *o : outputs())
        watch(o);
    connect(backend, &OutputBackend::outputAdded, this, [this](BackendOutput *o) {
        watch(o);
        schedule();
    });
    connect(backend, &OutputBackend::outputRemoved, this, &OutputManagement::schedule);
}

OutputManagement::~OutputManagement()
{
    wl_global_destroy(m_global);
    for (Manager *m : std::as_const(m_managers))
        m->self = nullptr;
}

void OutputManagement::forget(Manager *manager)
{
    m_managers.removeOne(manager);
}

void OutputManagement::watch(BackendOutput *o)
{
    // Every property the heads show.
    for (auto signal : {&BackendOutput::enabledChanged, &BackendOutput::positionChanged, &BackendOutput::scaleChanged,
                        &BackendOutput::currentModeChanged, &BackendOutput::modesChanged, &BackendOutput::transformChanged}) {
        connect(o, signal, this, &OutputManagement::schedule);
    }
}

// Several properties change in one go; the clients hear about them together.
void OutputManagement::schedule()
{
    if (m_pending)
        return;
    m_pending = true;
    QTimer::singleShot(0, this, [this] {
        m_pending = false;
        ++m_serial;
        syncAll();
    });
}

void OutputManagement::syncAll()
{
    for (Manager *m : std::as_const(m_managers))
        sync(m);
}

void OutputManagement::bind(wl_client *client, void *data, uint32_t version, uint32_t id)
{
    auto *self = static_cast<OutputManagement *>(data);
    auto *m = new Manager;
    m->client = client;
    m->self = self;
    m->resource = wl_resource_create(client, &zwlr_output_manager_v1_interface, version, id);
    wl_resource_set_implementation(m->resource, &s_managerImpl, m, managerDestroyed);
    self->m_managers << m;
    self->sync(m);
}

void OutputManagement::sync(Manager *m)
{
    if (m->stopped || !m->resource)
        return;
    const QList<BackendOutput *> present = outputs();
    for (auto it = m->heads.begin(); it != m->heads.end();) {
        if (present.contains(it.key())) {
            ++it;
            continue;
        }
        if (it.value())
            finishHead(it.value());
        it = m->heads.erase(it);
    }
    const uint32_t version = wl_resource_get_version(m->resource);
    for (BackendOutput *o : present) {
        const bool known = m->heads.contains(o);
        Head *h = m->heads.value(o);
        if (known && !h)
            continue; // released by the client
        if (!h) {
            h = new Head;
            h->manager = m;
            h->output = o;
            h->resource = wl_resource_create(m->client, &zwlr_output_head_v1_interface, version, 0);
            wl_resource_set_implementation(h->resource, &s_headImpl, h, headDestroyed);
            m->heads.insert(o, h);
            zwlr_output_manager_v1_send_head(m->resource, h->resource);
            zwlr_output_head_v1_send_name(h->resource, o->name().toUtf8().constData());
            zwlr_output_head_v1_send_description(h->resource, o->description().toUtf8().constData());
            zwlr_output_head_v1_send_physical_size(h->resource, o->physicalSize().width(), o->physicalSize().height());
            if (version >= ZWLR_OUTPUT_HEAD_V1_MAKE_SINCE_VERSION) {
                zwlr_output_head_v1_send_make(h->resource, o->manufacturer().toUtf8().constData());
                zwlr_output_head_v1_send_model(h->resource, o->model().toUtf8().constData());
                zwlr_output_head_v1_send_serial_number(h->resource, o->serialNumber().toUtf8().constData());
            }
        }
        sendModes(h, m->client);
        sendState(h);
    }
    zwlr_output_manager_v1_send_done(m->resource, m_serial);
}
