// mmsimpulse: KWin plugin that speaks the Wayland protocols shells written for
// wlroots compositors, niri and Hyprland expect, and KWin does not: the window
// list (wlr-foreign-toplevel-management, ext-foreign-toplevel-list) and
// workspaces (ext-workspace), and screenshots and window pictures (wlr-screencopy,
// ext-image-copy-capture), typing (zwp-virtual-keyboard) and
// display settings (wlr-output-management). With
// them a Quickshell shell, waybar and the like show windows and workspaces on
// KWin without knowing anything about it. It also keeps KWin's window
// animations off such a shell's panels.

#include "animations.h"
#include "imagecopy.h"
#include "outputmanagement.h"
#include "screencopy.h"
#include "toplevellist.h"
#include "toplevels.h"
#include "virtualkeyboard.h"
#include "workspaces.h"

#include <plugin.h>

using namespace KWin;

class MmsimpulsePlugin : public Plugin
{
public:
    MmsimpulsePlugin()
        : m_toplevels(std::make_unique<ForeignToplevels>())
        , m_toplevelList(std::make_unique<ToplevelList>())
        , m_screenCopy(std::make_unique<ScreenCopy>())
        , m_imageCopy(std::make_unique<ImageCopy>())
        , m_virtualKeyboards(std::make_unique<VirtualKeyboards>())
        , m_outputManagement(std::make_unique<OutputManagement>())
        , m_workspaces(std::make_unique<ExtWorkspaces>())
        , m_animations(std::make_unique<LayerAnimations>())
    {
    }

private:
    std::unique_ptr<ForeignToplevels> m_toplevels;
    std::unique_ptr<ToplevelList> m_toplevelList;
    std::unique_ptr<ScreenCopy> m_screenCopy;
    std::unique_ptr<ImageCopy> m_imageCopy;
    std::unique_ptr<VirtualKeyboards> m_virtualKeyboards;
    std::unique_ptr<OutputManagement> m_outputManagement;
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
