// mmsimpulse: KWin plugin that speaks the Wayland protocols shells written for
// wlroots compositors, niri and Hyprland expect, and KWin does not: the window
// list (wlr-foreign-toplevel-management) and workspaces (ext-workspace). With
// them a Quickshell shell, waybar and the like show windows and workspaces on
// KWin without knowing anything about it. It also keeps KWin's window
// animations off such a shell's panels.

#include "animations.h"
#include "toplevels.h"
#include "workspaces.h"

#include <plugin.h>

using namespace KWin;

class MmsimpulsePlugin : public Plugin
{
public:
    MmsimpulsePlugin()
        : m_toplevels(std::make_unique<ForeignToplevels>())
        , m_workspaces(std::make_unique<ExtWorkspaces>())
        , m_animations(std::make_unique<LayerAnimations>())
    {
    }

private:
    std::unique_ptr<ForeignToplevels> m_toplevels;
    std::unique_ptr<ExtWorkspaces> m_workspaces;
    std::unique_ptr<LayerAnimations> m_animations;
};

class MmsimpulsePluginFactory : public PluginFactory
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID PluginFactory_iid FILE "metadata.json")
    Q_INTERFACES(KWin::PluginFactory)

public:
    std::unique_ptr<Plugin> create() const override
    {
        return std::make_unique<MmsimpulsePlugin>();
    }
};

#include "main.moc"
