#pragma once

#include <QObject>

struct wl_client;
struct wl_global;

// zwp_virtual_keyboard_manager_v1: a client types as if it were a keyboard
// (wtype, on-screen keyboards, a shell pressing an app's shortcut).
//
// The client sends keys in a keymap of its own. KWin reads keys in the user's
// keymap, so each key is turned into the keysym it means and typed as the key
// that gives that keysym in the user's layout. A character the layout has no
// key for is not typed.
//
// As on wlroots compositors, any client may type.
class VirtualKeyboards : public QObject
{
public:
    VirtualKeyboards();
    ~VirtualKeyboards() override;

private:
    wl_global *m_global = nullptr;
};
