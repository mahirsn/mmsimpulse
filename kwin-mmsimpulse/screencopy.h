#pragma once

#include <QObject>

struct wl_client;
struct wl_global;

// zwlr_screencopy_manager_v1: a picture of an output, or of part of one, into
// a client's shared-memory buffer. Screenshot and recording tools written for
// wlroots compositors use it (grim, a shell's own capture button).
//
// Like on those compositors, any client may ask; KWin's own screenshot service
// asks the app to declare it. Windows marked to be hidden from capture stay
// hidden here too.
class ScreenCopy : public QObject
{
public:
    ScreenCopy();
    ~ScreenCopy() override;

private:
    static void bind(wl_client *client, void *data, uint32_t version, uint32_t id);

    wl_global *m_global = nullptr;
};
