#pragma once

// Pictures of an output or a window, rendered the way KWin's own screenshot
// plugin renders them, and written into a client's shared-memory buffer.
// wlr-screencopy and ext-image-copy-capture share them.

#include <QImage>
#include <QRect>

#include <optional>

struct wl_resource;

namespace KWin
{
class GraphicsBuffer;
class LogicalOutput;
class Window;
}

namespace mms
{

// The output as it is on screen, at its native resolution, top row first.
// Windows marked to be hidden from capture are left out.
std::optional<QImage> renderOutput(KWin::LogicalOutput *output, bool withCursor);

// One window with its titlebar, without its shadow, at its own scale.
std::optional<QImage> renderWindow(KWin::Window *window, bool withCursor);

// The client's shared-memory buffer behind a wl_buffer, or null. KWin keeps
// these itself, so libwayland's wl_shm_buffer_get() knows none of them.
KWin::GraphicsBuffer *shmBuffer(wl_resource *buffer);

// The wl_shm format of a shared-memory buffer (its attributes hold a DRM one),
// or -1 when it is not one the capture writes.
int shmFormat(KWin::GraphicsBuffer *buffer);

// Copies area of image into the buffer, in the buffer's format.
bool writeShm(KWin::GraphicsBuffer *buffer, const QImage &image, const QRect &area);

}
