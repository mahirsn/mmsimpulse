#include "screencopy.h"
#include "wlr-screencopy-unstable-v1-server-protocol.h"

#include "capture.h"

#include <core/graphicsbuffer.h>
#include <core/output.h>
#include <core/backendoutput.h>
#include <core/renderloop.h>
#include <wayland/display.h>
#include <wayland/output.h>
#include <wayland_server.h>

#include <wayland-server-protocol.h>

#include <QPointer>

#include <ctime>
#include <optional>

using namespace KWin;

static constexpr uint32_t s_version = 3;

namespace
{

struct Frame;

struct BufferWatch
{
    wl_listener listener; // first, so the listener's address is the watch's
    Frame *frame;
};

struct Frame
{
    wl_resource *resource = nullptr;
    QPointer<LogicalOutput> output;
    // In buffer pixels, within the output's native-resolution picture.
    QRect area;
    bool withCursor = false;
    bool used = false;
    // While copy_with_damage waits for the next frame.
    wl_resource *pendingBuffer = nullptr;
    BufferWatch watch{{}, this};
    QMetaObject::Connection presented;
    QMetaObject::Connection outputGone;
};

Frame *frameOf(wl_resource *resource)
{
    return static_cast<Frame *>(wl_resource_get_user_data(resource));
}

void sendReady(Frame *f)
{
    timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    const uint64_t sec = now.tv_sec;
    zwlr_screencopy_frame_v1_send_flags(f->resource, 0);
    zwlr_screencopy_frame_v1_send_ready(f->resource, sec >> 32, sec & 0xffffffff, now.tv_nsec);
}

// Renders the output into the client's buffer, which copy() already checked.
void copyInto(Frame *f, wl_resource *buffer, bool damage)
{
    GraphicsBuffer *shm = mms::shmBuffer(buffer);
    std::optional<QImage> image;
    if (f->output && shm)
        image = mms::renderOutput(f->output, f->withCursor);
    if (!image || !mms::writeShm(shm, *image, f->area)) {
        zwlr_screencopy_frame_v1_send_failed(f->resource);
        return;
    }
    if (damage)
        zwlr_screencopy_frame_v1_send_damage(f->resource, 0, 0, f->area.width(), f->area.height());
    sendReady(f);
}

void stopWaiting(Frame *f)
{
    QObject::disconnect(f->presented);
    QObject::disconnect(f->outputGone);
    if (f->pendingBuffer) {
        wl_list_remove(&f->watch.listener.link);
        f->pendingBuffer = nullptr;
    }
}

void copy(wl_resource *r, wl_resource *buffer, bool damage)
{
    Frame *f = frameOf(r);
    if (f->used) {
        wl_resource_post_error(r, ZWLR_SCREENCOPY_FRAME_V1_ERROR_ALREADY_USED, "frame already used");
        return;
    }
    GraphicsBuffer *shm = mms::shmBuffer(buffer);
    if (mms::shmFormat(shm) != WL_SHM_FORMAT_XRGB8888 || shm->size() != f->area.size()
        || shm->shmAttributes()->stride < f->area.width() * 4) {
        wl_resource_post_error(r, ZWLR_SCREENCOPY_FRAME_V1_ERROR_INVALID_BUFFER, "invalid buffer");
        return;
    }
    f->used = true;
    if (!f->output) {
        zwlr_screencopy_frame_v1_send_failed(f->resource);
        return;
    }
    if (!damage) {
        copyInto(f, buffer, false);
        return;
    }
    // copy_with_damage waits for the screen to change, which is what keeps a
    // recorder from copying the same picture in a loop. The next frame the
    // output shows is taken as that change.
    f->pendingBuffer = buffer;
    f->watch.listener.notify = [](wl_listener *listener, void *) {
        Frame *f = reinterpret_cast<BufferWatch *>(listener)->frame;
        stopWaiting(f);
        zwlr_screencopy_frame_v1_send_failed(f->resource);
    };
    wl_resource_add_destroy_listener(buffer, &f->watch.listener);
    RenderLoop *loop = f->output->backendOutput()->renderLoop();
    f->presented = QObject::connect(loop, &RenderLoop::framePresented, loop, [f] {
        wl_resource *buffer = f->pendingBuffer;
        stopWaiting(f);
        copyInto(f, buffer, true);
    });
    f->outputGone = QObject::connect(f->output, &QObject::destroyed, loop, [f] {
        stopWaiting(f);
        zwlr_screencopy_frame_v1_send_failed(f->resource);
    });
}

const struct zwlr_screencopy_frame_v1_interface s_frameImpl = {
    .copy = [](wl_client *, wl_resource *r, wl_resource *buffer) {
        copy(r, buffer, false);
    },
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
    .copy_with_damage = [](wl_client *, wl_resource *r, wl_resource *buffer) {
        copy(r, buffer, true);
    },
};

void frameDestroyed(wl_resource *resource)
{
    Frame *f = frameOf(resource);
    stopWaiting(f);
    delete f;
}

void capture(wl_client *client, wl_resource *manager, uint32_t id, int32_t overlayCursor,
             wl_resource *outputResource, std::optional<QRect> region)
{
    auto *f = new Frame;
    f->resource = wl_resource_create(client, &zwlr_screencopy_frame_v1_interface,
                                     wl_resource_get_version(manager), id);
    wl_resource_set_implementation(f->resource, &s_frameImpl, f, frameDestroyed);
    f->withCursor = overlayCursor != 0;

    OutputInterface *output = OutputInterface::get(outputResource);
    LogicalOutput *logical = output && !output->isRemoved() ? output->handle() : nullptr;
    if (!logical) {
        zwlr_screencopy_frame_v1_send_failed(f->resource);
        return;
    }
    f->output = logical;
    const qreal scale = logical->scale();
    const QRect whole(QPoint(), (logical->geometryF().size() * scale).toSize());
    // A region is in the output's logical coordinates.
    f->area = region ? QRectF(QPointF(region->topLeft()) * scale, QSizeF(region->size()) * scale).toAlignedRect() & whole
                     : whole;
    if (f->area.isEmpty()) {
        zwlr_screencopy_frame_v1_send_failed(f->resource);
        return;
    }
    zwlr_screencopy_frame_v1_send_buffer(f->resource, WL_SHM_FORMAT_XRGB8888,
                                         f->area.width(), f->area.height(), f->area.width() * 4);
    if (wl_resource_get_version(f->resource) >= ZWLR_SCREENCOPY_FRAME_V1_BUFFER_DONE_SINCE_VERSION)
        zwlr_screencopy_frame_v1_send_buffer_done(f->resource);
}

const struct zwlr_screencopy_manager_v1_interface s_managerImpl = {
    .capture_output = [](wl_client *client, wl_resource *r, uint32_t frame, int32_t cursor, wl_resource *output) {
        capture(client, r, frame, cursor, output, std::nullopt);
    },
    .capture_output_region = [](wl_client *client, wl_resource *r, uint32_t frame, int32_t cursor, wl_resource *output,
                                int32_t x, int32_t y, int32_t width, int32_t height) {
        capture(client, r, frame, cursor, output, QRect(x, y, width, height));
    },
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

} // namespace

ScreenCopy::ScreenCopy()
{
    m_global = wl_global_create(*waylandServer()->display(), &zwlr_screencopy_manager_v1_interface,
                                s_version, this, bind);
}

ScreenCopy::~ScreenCopy()
{
    wl_global_destroy(m_global);
}

void ScreenCopy::bind(wl_client *client, void *, uint32_t version, uint32_t id)
{
    wl_resource *r = wl_resource_create(client, &zwlr_screencopy_manager_v1_interface, version, id);
    wl_resource_set_implementation(r, &s_managerImpl, nullptr, nullptr);
}
