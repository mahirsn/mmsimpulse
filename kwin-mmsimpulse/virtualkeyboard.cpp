#include "virtualkeyboard.h"

#include "virtual-keyboard-unstable-v1-server-protocol.h"

#include <core/inputdevice.h>
#include <input.h>
#include <keyboard_input.h>
#include <wayland/display.h>
#include <wayland_server.h>
#include <xkb.h>

#include <xkbcommon/xkbcommon.h>

#include <QSet>

#include <linux/input-event-codes.h>
#include <sys/mman.h>
#include <unistd.h>

using namespace KWin;

namespace
{

class Device : public InputDevice
{
public:
    QString name() const override
    {
        return QStringLiteral("mmsimpulse virtual keyboard");
    }
    bool isEnabled() const override
    {
        return true;
    }
    void setEnabled(bool) override
    {
    }
    bool isKeyboard() const override
    {
        return true;
    }
    bool isPointer() const override
    {
        return false;
    }
    bool isTouchpad() const override
    {
        return false;
    }
    bool isTouch() const override
    {
        return false;
    }
    bool isTabletTool() const override
    {
        return false;
    }
    bool isTabletPad() const override
    {
        return false;
    }
    bool isTabletModeSwitch() const override
    {
        return false;
    }
    bool isLidSwitch() const override
    {
        return false;
    }
};

// The modifiers a client holds, by the name every keymap gives them, and the
// key that holds each one in the user's keymap.
struct Modifier
{
    const char *name;
    quint32 key;
};
constexpr Modifier s_modifiers[] = {
    {XKB_MOD_NAME_SHIFT, KEY_LEFTSHIFT},
    {XKB_MOD_NAME_CTRL, KEY_LEFTCTRL},
    {XKB_MOD_NAME_ALT, KEY_LEFTALT},
    {XKB_MOD_NAME_LOGO, KEY_LEFTMETA},
    // The third level: '@' on a Turkish or German layout is AltGr and a key.
    {"Mod5", KEY_RIGHTALT},
};

struct Keyboard
{
    std::unique_ptr<Device> device;
    xkb_context *context = nullptr;
    xkb_keymap *keymap = nullptr;
    xkb_state *state = nullptr;
    // What this keyboard holds down in the user's keymap, so that it can all
    // be let go when the client goes.
    QSet<quint32> held;
    QSet<quint32> heldModifiers;

    ~Keyboard()
    {
        const auto now = std::chrono::microseconds(0);
        for (quint32 key : std::as_const(held))
            Q_EMIT device->keyChanged(key, KeyboardKeyState::Released, now, device.get());
        for (quint32 key : std::as_const(heldModifiers))
            Q_EMIT device->keyChanged(key, KeyboardKeyState::Released, now, device.get());
        input()->removeInputDevice(device.get());
        if (state)
            xkb_state_unref(state);
        if (keymap)
            xkb_keymap_unref(keymap);
        xkb_context_unref(context);
    }

    void send(quint32 key, bool pressed, std::chrono::microseconds time)
    {
        Q_EMIT device->keyChanged(key, pressed ? KeyboardKeyState::Pressed : KeyboardKeyState::Released, time, device.get());
    }
};

Keyboard *keyboardOf(wl_resource *r)
{
    return static_cast<Keyboard *>(wl_resource_get_user_data(r));
}

// The evdev key that gives keysym in the user's keymap, and the modifiers of
// the user's keymap it needs for that.
std::optional<Xkb::KeyCode> userKey(xkb_keysym_t sym)
{
    return input()->keyboard()->xkb()->keycodeFromKeysym(sym);
}

void key(wl_resource *r, uint32_t time, uint32_t code, uint32_t state)
{
    Keyboard *k = keyboardOf(r);
    if (!k->state) {
        wl_resource_post_error(r, ZWP_VIRTUAL_KEYBOARD_V1_ERROR_NO_KEYMAP, "no keymap");
        return;
    }
    const auto when = std::chrono::milliseconds(time);
    const bool pressed = state == WL_KEYBOARD_KEY_STATE_PRESSED;
    const xkb_keysym_t sym = xkb_state_key_get_one_sym(k->state, code + 8);
    const auto user = sym == XKB_KEY_NoSymbol ? std::nullopt : userKey(sym);
    if (!user) {
        qWarning("mmsimpulse: virtual keyboard: no key for keysym 0x%x in the current layout", sym);
        return;
    }
    // KWin's keycodeFromKeysym() answers with the evdev code already.
    const quint32 evdev = user->keyCode;
    if (!pressed) {
        if (k->held.remove(evdev))
            k->send(evdev, false, when);
        return;
    }
    // Shift and the like that the layout needs for this keysym (an upper-case
    // letter, a symbol on a shifted level) and the client did not hold.
    xkb_keymap *keymap = input()->keyboard()->xkb()->keymap();
    QList<quint32> extra;
    for (const Modifier &m : s_modifiers) {
        const xkb_mod_index_t index = xkb_keymap_mod_get_index(keymap, m.name);
        if (index != XKB_MOD_INVALID && (user->modifiers & (1u << index)) && !k->heldModifiers.contains(m.key))
            extra << m.key;
    }
    for (quint32 m : std::as_const(extra))
        k->send(m, true, when);
    k->send(evdev, true, when);
    k->held.insert(evdev);
    if (!extra.isEmpty()) {
        // A level-chosen key is a single keystroke: let it and the modifiers go
        // now, the client's release finds nothing held.
        k->send(evdev, false, when);
        k->held.remove(evdev);
        for (quint32 m : std::as_const(extra))
            k->send(m, false, when);
    }
}

void modifiers(wl_resource *r, uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group)
{
    Keyboard *k = keyboardOf(r);
    if (!k->state) {
        wl_resource_post_error(r, ZWP_VIRTUAL_KEYBOARD_V1_ERROR_NO_KEYMAP, "no keymap");
        return;
    }
    xkb_state_update_mask(k->state, depressed, latched, locked, 0, 0, group);
    const auto now = std::chrono::microseconds(0);
    for (const Modifier &m : s_modifiers) {
        const bool on = xkb_state_mod_name_is_active(k->state, m.name, XKB_STATE_MODS_DEPRESSED) > 0;
        if (on && !k->heldModifiers.contains(m.key)) {
            k->heldModifiers.insert(m.key);
            k->send(m.key, true, now);
        } else if (!on && k->heldModifiers.remove(m.key)) {
            k->send(m.key, false, now);
        }
    }
}

const struct zwp_virtual_keyboard_v1_interface s_keyboardImpl = {
    .keymap = [](wl_client *, wl_resource *r, uint32_t format, int32_t fd, uint32_t size) {
        Keyboard *k = keyboardOf(r);
        if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
            close(fd);
            return;
        }
        void *data = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
        close(fd);
        if (data == MAP_FAILED)
            return;
        xkb_keymap *keymap = xkb_keymap_new_from_buffer(k->context, static_cast<const char *>(data), strnlen(static_cast<const char *>(data), size),
                                                        XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
        munmap(data, size);
        if (!keymap)
            return;
        if (k->state)
            xkb_state_unref(k->state);
        if (k->keymap)
            xkb_keymap_unref(k->keymap);
        k->keymap = keymap;
        k->state = xkb_state_new(keymap);
    },
    .key = [](wl_client *, wl_resource *r, uint32_t time, uint32_t code, uint32_t state) {
        key(r, time, code, state);
    },
    .modifiers = [](wl_client *, wl_resource *r, uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group) {
        modifiers(r, depressed, latched, locked, group);
    },
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

const struct zwp_virtual_keyboard_manager_v1_interface s_managerImpl = {
    .create_virtual_keyboard = [](wl_client *client, wl_resource *r, wl_resource *, uint32_t id) {
        auto *k = new Keyboard;
        k->device = std::make_unique<Device>();
        k->context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
        input()->addInputDevice(k->device.get());
        wl_resource *res = wl_resource_create(client, &zwp_virtual_keyboard_v1_interface, wl_resource_get_version(r), id);
        wl_resource_set_implementation(res, &s_keyboardImpl, k, [](wl_resource *res) {
            delete keyboardOf(res);
        });
    },
};

} // namespace

VirtualKeyboards::VirtualKeyboards()
{
    m_global = wl_global_create(*waylandServer()->display(), &zwp_virtual_keyboard_manager_v1_interface, 1, this,
                                [](wl_client *client, void *, uint32_t version, uint32_t id) {
                                    wl_resource *r = wl_resource_create(client, &zwp_virtual_keyboard_manager_v1_interface, version, id);
                                    wl_resource_set_implementation(r, &s_managerImpl, nullptr, nullptr);
                                });
}

VirtualKeyboards::~VirtualKeyboards()
{
    wl_global_destroy(m_global);
}
