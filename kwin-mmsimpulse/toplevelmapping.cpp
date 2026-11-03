#include "toplevelmapping.h"

#include "hyprland-toplevel-mapping-v1-server-protocol.h"
#include "toplevels.h"

#include <wayland/display.h>
#include <wayland_server.h>
#include <window.h>

using namespace KWin;

namespace
{

const struct hyprland_toplevel_window_mapping_handle_v1_interface s_handleImpl = {
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

wl_resource *newHandle(wl_client *client, wl_resource *manager, uint32_t id)
{
    wl_resource *r = wl_resource_create(client, &hyprland_toplevel_window_mapping_handle_v1_interface, wl_resource_get_version(manager), id);
    wl_resource_set_implementation(r, &s_handleImpl, nullptr, nullptr);
    return r;
}

const struct hyprland_toplevel_mapping_manager_v1_interface s_managerImpl = {
    // Its XML gives this request no arguments, so there is nothing to answer.
    .get_window_for_toplevel = [](wl_client *, wl_resource *) {},
    .get_window_for_toplevel_wlr = [](wl_client *client, wl_resource *manager, uint32_t id, wl_resource *toplevel) {
        wl_resource *r = newHandle(client, manager, id);
        if (Window *w = ForeignToplevels::window(toplevel)) {
            const quint64 a = ToplevelMapping::address(w);
            hyprland_toplevel_window_mapping_handle_v1_send_window_address(r, a >> 32, a & 0xffffffff);
        } else {
            hyprland_toplevel_window_mapping_handle_v1_send_failed(r);
        }
    },
    .destroy = [](wl_client *, wl_resource *r) {
        wl_resource_destroy(r);
    },
};

} // namespace

quint64 ToplevelMapping::address(Window *window)
{
    const QByteArray id = window->internalId().toRfc4122();
    quint64 a = 0;
    for (int i = 0; i < 6; ++i)
        a = (a << 8) | quint8(id[i]);
    return a;
}

ToplevelMapping::ToplevelMapping()
{
    m_global = wl_global_create(*waylandServer()->display(), &hyprland_toplevel_mapping_manager_v1_interface, 1, this,
                                [](wl_client *client, void *, uint32_t version, uint32_t id) {
                                    wl_resource *r = wl_resource_create(client, &hyprland_toplevel_mapping_manager_v1_interface, version, id);
                                    wl_resource_set_implementation(r, &s_managerImpl, nullptr, nullptr);
                                });
}

ToplevelMapping::~ToplevelMapping()
{
    wl_global_destroy(m_global);
}
