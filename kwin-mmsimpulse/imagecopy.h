#pragma once

#include <QObject>

struct wl_client;
struct wl_global;

// ext_image_copy_capture_v1 with its two sources, an output
// (ext_output_image_capture_source_manager_v1) and a window
// (ext_foreign_toplevel_image_capture_source_manager_v1, which names the
// window by its ext-foreign-toplevel-list handle). The newer screenshot and
// recording protocol, and the one shells take window previews with.
//
// As with wlr-screencopy, any client may ask, and windows marked to be hidden
// from capture stay hidden.
class ImageCopy : public QObject
{
public:
    ImageCopy();
    ~ImageCopy() override;

private:
    wl_global *m_outputSources = nullptr;
    wl_global *m_windowSources = nullptr;
    wl_global *m_manager = nullptr;
};
