#include "capture.h"

#include <compositor.h>
#include <core/backendoutput.h>
#include <core/graphicsbuffer.h>
#include <core/output.h>
#include <core/outputlayer.h>
#include <core/region.h>
#include <core/renderdevice.h>
#include <core/rendertarget.h>
#include <core/renderviewport.h>
#include <main.h>
#include <opengl/eglcontext.h>
#include <opengl/glframebuffer.h>
#include <opengl/gltexture.h>
#include <effect/effect.h>
#include <scene/decorationitem.h>
#include <scene/shadowitem.h>
#include <scene/itemrenderer.h>
#include <scene/scene.h>
#include <scene/windowitem.h>
#include <scene/workspacescene.h>
#include <wayland/display.h>
#include <window.h>
#include <workspace.h>

#include <drm_fourcc.h>
#include <wayland-server-protocol.h>

#include <QScopeGuard>

#include <cstring>

using namespace KWin;

namespace mms
{

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

} // namespace

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


std::optional<QImage> renderWindow(Window *window, bool withCursor)
{
    if (window->excludeFromCapture() || !window->windowItem())
        return std::nullopt;
    RenderDevice *device = Compositor::self()->primaryDevice();
    const auto context = device ? device->eglContext() : nullptr;
    if (!context || !context->makeCurrent())
        return std::nullopt;

    const qreal scale = window->targetScale();
    const RectF geometry = window->frameGeometry();
    const QSize size = (geometry.size() * scale).toSize();
    const auto texture = GLTexture::allocate(GL_RGBA8, size);
    if (!texture)
        return std::nullopt;
    texture->setContentTransform(OutputTransform::FlipY);
    GLFramebuffer target(texture.get());
    if (!target.valid())
        return std::nullopt;

    RenderTarget renderTarget(&target);
    RenderViewport viewport(geometry, scale, renderTarget, QPoint());
    WorkspaceScene *scene = kwinApp()->scene();
    auto renderer = scene->renderer(device);
    renderer->beginFrame(renderTarget, viewport);
    glClearColor(0.0, 0.0, 0.0, 0.0);
    glClear(GL_COLOR_BUFFER_BIT);
    WindowItem *item = window->windowItem();
    bool ok = renderer->renderItem(renderTarget, viewport, item, Scene::PAINT_WINDOW_TRANSFORMED, Region::infinite(),
                                   WindowPaintData{}, [item](Item *i) {
                                       return i == item->shadowItem();
                                   }, {});
    if (ok && withCursor && scene->cursorItem()->isVisible())
        ok = renderer->renderItem(renderTarget, viewport, scene->cursorItem(), 0, Region::infinite(), WindowPaintData{}, {}, {});
    renderer->endFrame();
    if (!ok)
        return std::nullopt;

    GLFramebuffer::pushFramebuffer(&target);
    QImage image(texture->size(), QImage::Format_RGBA8888_Premultiplied);
    context->glReadnPixels(0, 0, image.width(), image.height(), GL_RGBA, GL_UNSIGNED_BYTE,
                           image.sizeInBytes(), static_cast<GLvoid *>(image.bits()));
    GLFramebuffer::popFramebuffer();
    return image;
}

GraphicsBuffer *shmBuffer(wl_resource *buffer)
{
    GraphicsBuffer *b = KWin::Display::bufferForResource(buffer);
    return b && b->shmAttributes() ? b : nullptr;
}


int shmFormat(GraphicsBuffer *buffer)
{
    const ShmAttributes *attrs = buffer ? buffer->shmAttributes() : nullptr;
    if (!attrs)
        return -1;
    switch (attrs->format) {
    case DRM_FORMAT_XRGB8888:
        return WL_SHM_FORMAT_XRGB8888;
    case DRM_FORMAT_ARGB8888:
        return WL_SHM_FORMAT_ARGB8888;
    default:
        return -1;
    }
}

bool writeShm(GraphicsBuffer *buffer, const QImage &image, const QRect &area)
{
    const int format = shmFormat(buffer);
    if (format < 0 || !QRect(QPoint(), image.size()).contains(area))
        return false;
    const GraphicsBuffer::Map map = buffer->map(GraphicsBuffer::Write);
    if (!map.data)
        return false;
    // Both are 0xAARRGGBB words, little-endian in memory, as QImage's 32-bit
    // formats; ARGB8888 is premultiplied, as Wayland's alpha is.
    const QImage picture = image.copy(area).convertToFormat(
        format == WL_SHM_FORMAT_ARGB8888 ? QImage::Format_ARGB32_Premultiplied : QImage::Format_RGB32);
    auto *data = static_cast<uchar *>(map.data);
    const int rows = std::min(picture.height(), buffer->size().height());
    const int bytes = std::min<qsizetype>(picture.bytesPerLine(), map.stride);
    for (int y = 0; y < rows; ++y)
        std::memcpy(data + y * map.stride, picture.constScanLine(y), bytes);
    buffer->unmap();
    return true;
}

}
