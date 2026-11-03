#pragma once

#include <QObject>

struct wl_global;

namespace KWin
{
class Window;
}

// hyprland_toplevel_mapping_manager_v1: the Hyprland window address of a
// wlr foreign toplevel, for shells that also speak Hyprland's IPC (Quickshell
// ties its toplevels to Hyprland's windows with it). The address is the first
// 48 bits of KWin's window id, as the bridge's Hyprland IPC gives it.
class ToplevelMapping : public QObject
{
public:
    ToplevelMapping();
    ~ToplevelMapping() override;

    static quint64 address(KWin::Window *window);

private:
    wl_global *m_global = nullptr;
};
