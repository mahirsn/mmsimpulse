#include "imagecopy.h"

#include "ext-image-capture-source-v1-server-protocol.h"
#include "ext-image-copy-capture-v1-server-protocol.h"

#include "capture.h"
#include "toplevellist.h"

#include <core/backendoutput.h>
#include <core/graphicsbuffer.h>
#include <core/output.h>
#include <core/renderloop.h>
#include <wayland/display.h>
#include <wayland/output.h>
#include <wayland_server.h>
#include <window.h>

#include <wayland-server-protocol.h>

#include <QPointer>

#include <ctime>

using namespace KWin;

namespace
{

// What a source stands for: one output or one window. Null when it is gone.
struct Source
{
    QPointer<LogicalOutput> output;
    QPointer<Window> window;
};

struct Frame;

struct Session
{
    wl_resource *resource = nullptr;
    Source source;
    bool withCursor = false;
    bool stopped = false;
    // A session's first frame is taken at once, every later one when the
    // picture next changes.
    bool captured = false;
    QSize size;
    Frame *frame = nullptr;
    QMetaObject::Connection resized;
    QMetaObject::Connection rescaled;
    QMetaObject::Connection gone;
};

struct BufferWatch
{
    wl_listener listener; // first, so the listener's address is the watch's
    Frame *frame;
};

struct Frame
{
    wl_resource *resource = nullptr;
    Session *session = nullptr;
    wl_resource *buffer = nullptr;
    bool captured = false;
    // Between capture and its answer, while it waits for the next picture.
    bool waiting = false;
    BufferWatch watch{{}, this};
    QMetaObject::Connection presented;
    QMetaObject::Connection outputGone;
};

// The size a source's pictures are, in buffer pixels; empty when it has none.
QSize sizeOf(const Source &s)
{
    if (s.output)
        return (s.output->geometryF().size() * s.output->scale()).toSize();
    if (s.window)
        return (s.window->frameGeometry().size() * s.window->targetScale()).toSize();
    return {};
}

LogicalOutput *outputOf(const Source &s)
{
    return s.output ? s.output.data() : s.window ? s.window->output() : nullptr;
}

// ---------------------------------------------------------------------------
// Sources
// ---------------------------------------------------------------------------

const struct ext_image_capture_source_v1_interface s_sourceImpl = {
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

Source *sourceOf(wl_resource *resource)
{
    if (!wl_resource_instance_of(resource, &ext_image_capture_source_v1_interface, &s_sourceImpl))
        return nullptr;
    return static_cast<Source *>(wl_resource_get_user_data(resource));
}

void createSource(wl_client *client, wl_resource *manager, uint32_t id, Source source)
{
    wl_resource *r = wl_resource_create(client, &ext_image_capture_source_v1_interface,
                                        wl_resource_get_version(manager), id);
    wl_resource_set_implementation(r, &s_sourceImpl, new Source(source), [](wl_resource *r) {
        delete static_cast<Source *>(wl_resource_get_user_data(r));
    });
}

const struct ext_output_image_capture_source_manager_v1_interface s_outputSourcesImpl = {
    .create_source = [](wl_client *client, wl_resource *r, uint32_t id, wl_resource *output) {
        OutputInterface *o = OutputInterface::get(output);
        createSource(client, r, id, Source{o && !o->isRemoved() ? o->handle() : nullptr, nullptr});
    },
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

const struct ext_foreign_toplevel_image_capture_source_manager_v1_interface s_windowSourcesImpl = {
    .create_source = [](wl_client *client, wl_resource *r, uint32_t id, wl_resource *handle) {
        createSource(client, r, id, Source{nullptr, ToplevelList::window(handle)});
    },
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

Frame *frameOf(wl_resource *r)
{
    return static_cast<Frame *>(wl_resource_get_user_data(r));
}

void stopWaiting(Frame *f)
{
    f->waiting = false;
    QObject::disconnect(f->presented);
    QObject::disconnect(f->outputGone);
    if (f->buffer) {
        wl_list_remove(&f->watch.listener.link);
        f->buffer = nullptr;
    }
}

void fail(Frame *f, uint32_t reason)
{
    stopWaiting(f);
    ext_image_copy_capture_frame_v1_send_failed(f->resource, reason);
}

void deliver(Frame *f)
{
    Session *s = f->session;
    wl_resource *buffer = f->buffer;
    stopWaiting(f);
    if (!s || s->stopped) {
        ext_image_copy_capture_frame_v1_send_failed(f->resource, EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_STOPPED);
        return;
    }
    GraphicsBuffer *shm = mms::shmBuffer(buffer);
    if (!shm || shm->size() != s->size) {
        ext_image_copy_capture_frame_v1_send_failed(f->resource, EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_BUFFER_CONSTRAINTS);
        return;
    }
    const std::optional<QImage> image = s->source.output ? mms::renderOutput(s->source.output, s->withCursor)
                                                         : mms::renderWindow(s->source.window, s->withCursor);
    if (!image || !mms::writeShm(shm, *image, QRect(QPoint(), s->size))) {
        ext_image_copy_capture_frame_v1_send_failed(f->resource, EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_UNKNOWN);
        return;
    }
    s->captured = true;
    timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    const uint64_t sec = now.tv_sec;
    ext_image_copy_capture_frame_v1_send_transform(f->resource, WL_OUTPUT_TRANSFORM_NORMAL);
    ext_image_copy_capture_frame_v1_send_damage(f->resource, 0, 0, s->size.width(), s->size.height());
    ext_image_copy_capture_frame_v1_send_presentation_time(f->resource, sec >> 32, sec & 0xffffffff, now.tv_nsec);
    ext_image_copy_capture_frame_v1_send_ready(f->resource);
}

void capture(wl_resource *r)
{
    Frame *f = frameOf(r);
    if (f->captured) {
        wl_resource_post_error(r, EXT_IMAGE_COPY_CAPTURE_FRAME_V1_ERROR_ALREADY_CAPTURED, "frame already captured");
        return;
    }
    if (!f->buffer) {
        wl_resource_post_error(r, EXT_IMAGE_COPY_CAPTURE_FRAME_V1_ERROR_NO_BUFFER, "no buffer attached");
        return;
    }
    f->captured = true;
    Session *s = f->session;
    if (!s || s->stopped) {
        fail(f, EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_STOPPED);
        return;
    }
    if (mms::shmFormat(mms::shmBuffer(f->buffer)) < 0) {
        fail(f, EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_BUFFER_CONSTRAINTS);
        return;
    }
    LogicalOutput *output = outputOf(s->source);
    if (!s->captured || !output) {
        deliver(f);
        return;
    }
    // Later frames wait for the screen to change, which keeps a recorder from
    // copying the same picture in a loop: the next frame the output shows.
    RenderLoop *loop = output->backendOutput()->renderLoop();
    f->waiting = true;
    f->presented = QObject::connect(loop, &RenderLoop::framePresented, loop, [f] {
        deliver(f);
    });
    // The output going takes its render loop along, and the picture it would
    // have announced never comes: answer now. An output source stops its
    // session then; a window is on another output by now.
    f->outputGone = QObject::connect(output, &QObject::destroyed, output, [f] {
        deliver(f);
    });
}

const struct ext_image_copy_capture_frame_v1_interface s_frameImpl = {
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
    .attach_buffer = [](wl_client *, wl_resource *r, wl_resource *buffer) {
        Frame *f = frameOf(r);
        if (f->captured)
            return;
        if (f->buffer)
            wl_list_remove(&f->watch.listener.link);
        f->buffer = buffer;
        f->watch.listener.notify = [](wl_listener *listener, void *) {
            Frame *f = reinterpret_cast<BufferWatch *>(listener)->frame;
            const bool waiting = f->waiting;
            stopWaiting(f);
            if (waiting)
                ext_image_copy_capture_frame_v1_send_failed(f->resource, EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_UNKNOWN);
        };
        wl_resource_add_destroy_listener(buffer, &f->watch.listener);
    },
    // Every frame is sent whole, so the client's damage changes nothing.
    .damage_buffer = [](wl_client *, wl_resource *r, int32_t x, int32_t y, int32_t width, int32_t height) {
        if (x < 0 || y < 0 || width <= 0 || height <= 0)
            wl_resource_post_error(r, EXT_IMAGE_COPY_CAPTURE_FRAME_V1_ERROR_INVALID_BUFFER_DAMAGE, "invalid damage");
    },
    .capture = [](wl_client *, wl_resource *r) {
        capture(r);
    },
};

void frameDestroyed(wl_resource *r)
{
    Frame *f = frameOf(r);
    stopWaiting(f);
    if (f->session)
        f->session->frame = nullptr;
    delete f;
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

Session *sessionOf(wl_resource *r)
{
    return static_cast<Session *>(wl_resource_get_user_data(r));
}

void sendConstraints(Session *s)
{
    s->size = sizeOf(s->source);
    ext_image_copy_capture_session_v1_send_buffer_size(s->resource, s->size.width(), s->size.height());
    ext_image_copy_capture_session_v1_send_shm_format(s->resource, WL_SHM_FORMAT_XRGB8888);
    ext_image_copy_capture_session_v1_send_shm_format(s->resource, WL_SHM_FORMAT_ARGB8888);
    ext_image_copy_capture_session_v1_send_done(s->resource);
}

void stop(Session *s)
{
    if (s->stopped)
        return;
    s->stopped = true;
    QObject::disconnect(s->resized);
    QObject::disconnect(s->rescaled);
    QObject::disconnect(s->gone);
    ext_image_copy_capture_session_v1_send_stopped(s->resource);
    if (s->frame && s->frame->waiting)
        fail(s->frame, EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_STOPPED);
}

const struct ext_image_copy_capture_session_v1_interface s_sessionImpl = {
    .create_frame = [](wl_client *client, wl_resource *r, uint32_t id) {
        Session *s = sessionOf(r);
        if (s->frame) {
            wl_resource_post_error(r, EXT_IMAGE_COPY_CAPTURE_SESSION_V1_ERROR_DUPLICATE_FRAME, "a frame already exists");
            return;
        }
        auto *f = new Frame;
        f->session = s;
        f->resource = wl_resource_create(client, &ext_image_copy_capture_frame_v1_interface, wl_resource_get_version(r), id);
        wl_resource_set_implementation(f->resource, &s_frameImpl, f, frameDestroyed);
        s->frame = f;
    },
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

void sessionDestroyed(wl_resource *r)
{
    Session *s = sessionOf(r);
    QObject::disconnect(s->resized);
    QObject::disconnect(s->rescaled);
    QObject::disconnect(s->gone);
    if (s->frame) {
        stopWaiting(s->frame);
        s->frame->session = nullptr;
    }
    delete s;
}

Session *createSession(wl_client *client, wl_resource *parent, uint32_t id, const Source &source, bool withCursor)
{
    auto *s = new Session;
    s->source = source;
    s->withCursor = withCursor;
    s->resource = wl_resource_create(client, &ext_image_copy_capture_session_v1_interface, wl_resource_get_version(parent), id);
    wl_resource_set_implementation(s->resource, &s_sessionImpl, s, sessionDestroyed);
    QObject *watched = source.output ? static_cast<QObject *>(source.output.data()) : source.window.data();
    if (!watched || sizeOf(source).isEmpty()) {
        stop(s);
        return s;
    }
    sendConstraints(s);
    // A different size is a new buffer the client has to allocate.
    const auto resize = [s] {
        if (!s->stopped && sizeOf(s->source) != s->size)
            sendConstraints(s);
    };
    if (source.output) {
        s->resized = QObject::connect(source.output, &LogicalOutput::geometryChanged, source.output, resize);
        s->rescaled = QObject::connect(source.output, &LogicalOutput::scaleChanged, source.output, resize);
        s->gone = QObject::connect(source.output, &QObject::destroyed, source.output, [s] {
            stop(s);
        });
    } else {
        s->resized = QObject::connect(source.window, &Window::frameGeometryChanged, source.window, resize);
        s->gone = QObject::connect(source.window, &Window::closed, source.window, [s] {
            stop(s);
        });
    }
    return s;
}

// The cursor as a picture of its own is not offered: its session stops at once,
// and a client then draws the cursor into the main picture with paint_cursors.
struct CursorSession
{
    bool used = false;
};

const struct ext_image_copy_capture_cursor_session_v1_interface s_cursorImpl = {
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
    .get_capture_session = [](wl_client *client, wl_resource *r, uint32_t id) {
        auto *c = static_cast<CursorSession *>(wl_resource_get_user_data(r));
        if (c->used) {
            wl_resource_post_error(r, EXT_IMAGE_COPY_CAPTURE_CURSOR_SESSION_V1_ERROR_DUPLICATE_SESSION, "session already created");
            return;
        }
        c->used = true;
        createSession(client, r, id, Source{}, false);
    },
};

const struct ext_image_copy_capture_manager_v1_interface s_managerImpl = {
    .create_session = [](wl_client *client, wl_resource *r, uint32_t id, wl_resource *source, uint32_t options) {
        if (options & ~uint32_t(EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_OPTIONS_PAINT_CURSORS)) {
            wl_resource_post_error(r, EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_ERROR_INVALID_OPTION, "invalid option");
            return;
        }
        const Source *src = sourceOf(source);
        createSession(client, r, id, src ? *src : Source{}, options & EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_OPTIONS_PAINT_CURSORS);
    },
    .create_pointer_cursor_session = [](wl_client *client, wl_resource *r, uint32_t id, wl_resource *, wl_resource *) {
        wl_resource *c = wl_resource_create(client, &ext_image_copy_capture_cursor_session_v1_interface, wl_resource_get_version(r), id);
        wl_resource_set_implementation(c, &s_cursorImpl, new CursorSession, [](wl_resource *r) {
            delete static_cast<CursorSession *>(wl_resource_get_user_data(r));
        });
    },
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

template<typename Interface>
wl_global *global(const wl_interface *interface, const Interface *impl)
{
    return wl_global_create(*waylandServer()->display(), interface, 1, const_cast<Interface *>(impl),
                            [](wl_client *client, void *data, uint32_t version, uint32_t id) {
                                const wl_interface *iface = nullptr;
                                if (data == &s_outputSourcesImpl)
                                    iface = &ext_output_image_capture_source_manager_v1_interface;
                                else if (data == &s_windowSourcesImpl)
                                    iface = &ext_foreign_toplevel_image_capture_source_manager_v1_interface;
                                else
                                    iface = &ext_image_copy_capture_manager_v1_interface;
                                wl_resource *r = wl_resource_create(client, iface, version, id);
                                wl_resource_set_implementation(r, data, nullptr, nullptr);
                            });
}

} // namespace

ImageCopy::ImageCopy()
    : m_outputSources(global(&ext_output_image_capture_source_manager_v1_interface, &s_outputSourcesImpl))
    , m_windowSources(global(&ext_foreign_toplevel_image_capture_source_manager_v1_interface, &s_windowSourcesImpl))
    , m_manager(global(&ext_image_copy_capture_manager_v1_interface, &s_managerImpl))
{
}

ImageCopy::~ImageCopy()
{
    wl_global_destroy(m_outputSources);
    wl_global_destroy(m_windowSources);
    wl_global_destroy(m_manager);
}
