#include "screencopy.h"

#include "wlr-screencopy-unstable-v1-server-protocol.h"

#include <compositor.h>
#include <core/backendoutput.h>
#include <core/output.h>
#include <core/outputlayer.h>
#include <core/graphicsbuffer.h>
#include <core/region.h>
#include <core/renderdevice.h>
#include <core/renderloop.h>
#include <core/rendertarget.h>
#include <main.h>
#include <opengl/eglcontext.h>
#include <opengl/glframebuffer.h>
#include <opengl/gltexture.h>
#include <scene/scene.h>
#include <scene/workspacescene.h>
#include <wayland/display.h>
#include <wayland/output.h>
#include <wayland_server.h>
#include <window.h>
#include <workspace.h>

#include <drm_fourcc.h>

#include <QImage>
#include <QScopeGuard>
#include <QPointer>

#include <cstring>
#include <ctime>
#include <optional>

using namespace KWin;

static constexpr uint32_t s_version = 3;

namespace
{

// An output layer that draws into our own framebuffer instead of onto the
// screen. The same as the one in KWin's screenshot plugin, which is private
// to that plugin.
class CaptureLayer : public OutputLayer
{
public:
    CaptureLayer(LogicalOutput *output, GLFramebuffer *buffer)
        : OutputLayer(output->backendOutput(), OutputLayerType::Primary)
        , m_buffer(buffer)
    {
    }

    FormatModifierMap supportedDrmFormats() const override
    {
        return {};
    }
    void releaseBuffers() override
    {
    }
    std::optional<OutputLayerBeginFrameInfo> beginFrame(OutputFrame * = nullptr) override
    {
        if (!m_buffer->context()->makeCurrent())
            return std::nullopt;
        return OutputLayerBeginFrameInfo{
            .renderTarget = RenderTarget(m_buffer),
            .repaint = Region::infinite(),
        };
    }
    bool endFrame(const Region &, const Region &, OutputFrame *) override
    {
        return true;
    }

private:
    GLFramebuffer *const m_buffer;
};

// The output as it is on screen, at its native resolution, top row first.
// Rendered the way KWin's screenshot plugin renders it.
std::optional<QImage> renderOutput(LogicalOutput *output, bool withCursor)
{
    RenderDevice *device = Compositor::self()->primaryDevice();
    const auto context = device ? device->eglContext() : nullptr;
    if (!context || !context->makeCurrent())
        return std::nullopt;

    const qreal scale = output->scale();
    const QSize size = (output->geometryF().size() * scale).toSize();
    const auto texture = GLTexture::allocate(GL_RGBA8, size);
    if (!texture)
        return std::nullopt;
    texture->setContentTransform(OutputTransform::FlipY);
    const auto target = std::make_unique<GLFramebuffer>(texture.get());
    if (!target->valid())
        return std::nullopt;

    CaptureLayer layer(output, target.get());
    if (!layer.preparePresentationTest())
        return std::nullopt;
    SceneView view(kwinApp()->scene(), output, nullptr, &layer, device);
    std::unique_ptr<ItemTreeView> hideCursor;
    if (!withCursor) {
        hideCursor = std::make_unique<ItemTreeView>(&view, kwinApp()->scene()->cursorItem(), workspace()->outputs().front(), nullptr, nullptr);
        hideCursor->setExclusive(true);
    }
    view.addWindowFilter([](Window *window) {
        return window->excludeFromCapture();
    });
    const Rect damage(QPoint(), target->size());
    view.setViewport(output->geometryF());
    view.setScale(scale);
    view.prePaint();
    const auto painted = qScopeGuard([&view] {
        view.postPaint();
    });
    const auto begin = layer.beginFrame();
    if (!begin)
        return std::nullopt;
    view.paint(begin->renderTarget, QPoint(), damage);
    if (!layer.endFrame(damage, damage, nullptr))
        return std::nullopt;

    GLFramebuffer::pushFramebuffer(target.get());
    QImage image(texture->size(), QImage::Format_RGBA8888_Premultiplied);
    context->glReadnPixels(0, 0, image.width(), image.height(), GL_RGBA, GL_UNSIGNED_BYTE,
                           image.sizeInBytes(), static_cast<GLvoid *>(image.bits()));
    GLFramebuffer::popFramebuffer();
    return image;
}

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

// KWin keeps shared-memory buffers itself, so libwayland's wl_shm_buffer_get()
// knows none of them: the buffer is KWin's, its format a DRM one.
GraphicsBuffer *shmBuffer(wl_resource *buffer)
{
    GraphicsBuffer *b = KWin::Display::bufferForResource(buffer);
    return b && b->shmAttributes() ? b : nullptr;
}

// Renders the output into the client's buffer, which copy() already checked.
void copyInto(Frame *f, wl_resource *buffer, bool damage)
{
    GraphicsBuffer *shm = shmBuffer(buffer);
    std::optional<QImage> image;
    if (f->output && shm)
        image = renderOutput(f->output, f->withCursor);
    if (!image || !QRect(QPoint(), image->size()).contains(f->area)) {
        zwlr_screencopy_frame_v1_send_failed(f->resource);
        return;
    }
    const GraphicsBuffer::Map map = shm->map(GraphicsBuffer::Write);
    if (!map.data) {
        zwlr_screencopy_frame_v1_send_failed(f->resource);
        return;
    }
    // XRGB8888 is QImage's RGB32: 0xffRRGGBB, little-endian in memory.
    const QImage picture = image->copy(f->area).convertToFormat(QImage::Format_RGB32);
    auto *data = static_cast<uchar *>(map.data);
    for (int y = 0; y < picture.height(); ++y)
        std::memcpy(data + y * map.stride, picture.constScanLine(y), picture.width() * 4);
    shm->unmap();
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
    GraphicsBuffer *shm = shmBuffer(buffer);
    const ShmAttributes *attrs = shm ? shm->shmAttributes() : nullptr;
    if (!attrs || attrs->format != DRM_FORMAT_XRGB8888 || attrs->size != f->area.size()
        || attrs->stride < f->area.width() * 4) {
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
