#!/usr/bin/env python3
"""Rewrite the upstream skin's Hyprland-only code paths for KWin.

The skin routes most compositor access through services/WM.qml, but a good
number of files reach past it and call Quickshell.Hyprland directly. Those
calls return null under KWin, which is what breaks the launcher (the overview
panel gets no monitor geometry) and pins the session screen to the first
screen instead of the focused one.

Applied as scripted edits rather than shipping full copies of ~20 upstream
files, so re-copying an updated skin keeps working — and every rule is checked,
so an upstream rename fails the install loudly instead of silently leaving a
Hyprland call behind.

Usage: patch-shell.py <shell-config-dir>
"""

import pathlib
import re
import sys

# Files that are supposed to talk to a specific compositor directly.
EXCLUDE = {
    "services/HyprlandBackend.qml",
    "services/NiriBackend.qml",
    "services/KwinBackend.qml",
    "services/HyprlandData.qml",
    "services/HyprlandConfig.qml",
    "services/HyprlandKeybinds.qml",
    "services/HyprlandXkb.qml",
    "modules/ii/overview/NiriOverview.qml",
    # already branches on WM.compositor everywhere it touches Hyprland
    "modules/common/models/WorkspaceModel.qml",
}

# Applied to every .qml, .sh and .py outside EXCLUDE.
#
# Directories.qml points the shell at ~/.config/mmsimpulse so this session and
# the Hyprland one stop overwriting each other's settings, but a dozen scripts
# and a couple of QML sites spell the old directory out by hand. Left alone
# they keep reading and writing the Hyprland session's config: presets save
# where nothing looks for them, and the colour scripts generate themes from
# stale settings.
#
# Deliberately narrow: it matches the path only. `illogical-impulse` is also
# the keyring attribute the stored API keys live under, and renaming that
# would lose them.
CONFIG_DIR = [
    (".config/illogical-impulse", ".config/mmsimpulse"),
    ("/illogical-impulse/config.json", "/mmsimpulse/config.json"),
    ('XDG_CONFIG_HOME/illogical-impulse"', 'XDG_CONFIG_HOME/mmsimpulse"'),
]

# (old, new) applied to every .qml outside EXCLUDE. Order matters: the longer
# ".values" forms have to run before the bare ones.
GLOBAL = [
    # hyprpicker speaks wlr-screencopy, which KWin does not implement, so the
    # bar's colour picker button did nothing at all. mmsimpulse-colorpicker is
    # the same feature over the desktop portal, which KDE's backend implements.
    ('"hyprpicker", "-a"', '"mmsimpulse-colorpicker"'),
    ("Hyprland.focusedMonitor", "WM.focusedMonitor"),
    ("Hyprland.monitorFor(", "WM.monitorFor("),
    ("Hyprland.monitors.values", "WM.monitors"),
    ("Hyprland.monitors", "WM.monitors"),
    ("Hyprland.workspaces.values", "WM.workspaces"),
    # HyprlandMonitor/HyprlandWorkspace are Hyprland-specific QML types; the
    # WM contract hands out plain objects.
    ("property HyprlandMonitor ", "property var "),
    ("list<HyprlandWorkspace>", "var"),
    # KWin's virtual desktops are global rather than per-output, so a workspace
    # with no monitor of its own belongs to every monitor.
    ("workspace.monitor && workspace.monitor.name == monitor.name",
     "(!workspace.monitor || workspace.monitor.name == monitor.name)"),
    # Hyprland workspace objects carry a `toplevels` model; the WM contract
    # answers the same question with fullscreenOnMonitor(). Used by the bar,
    # the background and the screen corners to get out of the way.
    ("workspacesForMonitor.filter(workspace => ((workspace.toplevels.values"
     ".filter(window => window.wayland?.fullscreen)[0] != undefined) && workspace.active))[0]",
     "WM.fullscreenOnMonitor(monitor?.name) ? workspacesForMonitor[0] : undefined"),
]

# (relative path, old, new) — exact, single-file edits.
SPECIFIC = [
    # --- overview / launcher ------------------------------------------------
    ("modules/ii/overview/Overview.qml",
     'Hyprland.dispatch("workspace r-1");',
     'WM.switchWorkspaceRelative("prev");'),
    ("modules/ii/overview/Overview.qml",
     'Hyprland.dispatch("workspace r+1");',
     'WM.switchWorkspaceRelative("next");'),
    ("modules/ii/overview/OverviewWidget.qml",
     'Hyprland.dispatch(`hl.dsp.focus({ workspace = ${workspace.workspaceValue} })`)',
     'WM.switchWorkspace(workspace.workspaceValue)'),
    ("modules/ii/overview/OverviewWidget.qml",
     'Hyprland.dispatch(`hl.dsp.window.move({ workspace = ${targetWorkspace}, follow = false, window = "address:${window.windowData?.address}" })`)',
     'WM.moveWindowToWorkspace(window.windowData?.address, targetWorkspace)'),
    ("modules/ii/overview/OverviewWidget.qml",
     'Hyprland.dispatch(`hl.dsp.focus({ window = "address:${windowData.address}" })`)',
     'WM.focusWindow(windowData.address)'),
    ("modules/ii/overview/OverviewWidget.qml",
     'Hyprland.dispatch(`hl.dsp.window.close({ window = "address:${windowData.address}" })`)',
     'WM.closeWindow(windowData.address)'),
    # Dragging a floating window to a free-form position has no KWin D-Bus
    # equivalent, so it stays Hyprland-only rather than silently doing nothing.
    ("modules/ii/overview/OverviewWidget.qml",
     'Hyprland.dispatch(`hl.dsp.window.move({ x = "${percentageX * root.screen.width}", y = "${percentageY * root.screen.height}", window = "address:${window.windowData?.address}" })`)',
     'if (WM.compositor === "hyprland") Hyprland.dispatch(`hl.dsp.window.move({ x = "${percentageX * root.screen.width}", y = "${percentageY * root.screen.height}", window = "address:${window.windowData?.address}" })`)'),

    # --- overview data source ----------------------------------------------
    # The overview was written straight against HyprlandData. KwinBackend hands
    # out the same `hyprctl clients -j` / `hyprctl monitors -j` shapes, so the
    # widget only needs pointing at WM when Hyprland is not the compositor.
    ("modules/ii/overview/OverviewWidget.qml",
     "property var windows: HyprlandData.windowList",
     'property var windows: WM.compositor === "hyprland" ? HyprlandData.windowList : WM.windowList'),
    ("modules/ii/overview/OverviewWidget.qml",
     "property var windowByAddress: HyprlandData.windowByAddress",
     'property var windowByAddress: WM.compositor === "hyprland" ? HyprlandData.windowByAddress : WM.windowByAddress'),
    ("modules/ii/overview/OverviewWidget.qml",
     "property var windowAddresses: HyprlandData.addresses",
     'property var windowAddresses: WM.compositor === "hyprland" ? HyprlandData.addresses : WM.addresses'),
    # Without this fallback monitorData is undefined, every workspace dimension
    # computes to NaN, and the Row above the search box spins in a polish loop
    # that leaves the launcher an empty rectangle.
    ("modules/ii/overview/OverviewWidget.qml",
     "property var monitorData: HyprlandData.monitors.find(m => m.id === root.monitor?.id)",
     "property var monitorData: HyprlandData.monitors.find(m => m.id === root.monitor?.id) ?? root.monitor"),

    # KWin implements none of the foreign-toplevel protocols ToplevelManager
    # needs, so its list is always empty here and the overview would show no
    # windows at all. Drive the repeater off the window list instead; the
    # delegate then renders the icon and frame without a live preview.
    ("modules/ii/overview/OverviewWidget.qml",
     """                    values: {
                        // console.log(JSON.stringify(ToplevelManager.toplevels.values.map(t => t), null, 2))
                        return ToplevelManager.toplevels.values.filter((toplevel) => {
                            const address = `0x${toplevel.HyprlandToplevel?.address}`
                            var win = windowByAddress[address]
                            const inWorkspaceGroup = (root.workspaceGroup * root.workspacesShown < win?.workspace?.id && win?.workspace?.id <= (root.workspaceGroup + 1) * root.workspacesShown)
                            return inWorkspaceGroup;
                        })
                    }""",
     """                    values: {
                        const inGroup = win => (root.workspaceGroup * root.workspacesShown < win?.workspace?.id && win?.workspace?.id <= (root.workspaceGroup + 1) * root.workspacesShown)
                        // A Hyprland workspace belongs to one output, so the
                        // cell is already that output's view. A KWin desktop
                        // spans every output, so restrict it here or windows
                        // from the other screens land on top of these.
                        if (WM.compositor !== "hyprland")
                            return root.windows.filter(w => inGroup(w) && w.output === root.monitor?.name)
                        return ToplevelManager.toplevels.values.filter((toplevel) => {
                            const address = `0x${toplevel.HyprlandToplevel?.address}`
                            return inGroup(windowByAddress[address]);
                        })
                    }"""),
    ("modules/ii/overview/OverviewWidget.qml",
     """                    property var address: `0x${modelData.HyprlandToplevel.address}`
                    toplevel: modelData""",
     """                    property var address: WM.compositor === "hyprland" ? `0x${modelData.HyprlandToplevel.address}` : modelData.address
                    toplevel: WM.compositor === "hyprland" ? modelData : null"""),
    ("modules/ii/overview/OverviewWidget.qml",
     "property var monitor: HyprlandData.monitors.find(m => m.id == monitorId)",
     "property var monitor: HyprlandData.monitors.find(m => m.id == monitorId) ?? WM.monitors.find(m => m.id == monitorId)"),
    ("modules/ii/overview/OverviewWidget.qml",
     "widgetMonitor: HyprlandData.monitors.find(m => m.id == root.monitor.id)",
     "widgetMonitor: HyprlandData.monitors.find(m => m.id == root.monitor.id) ?? root.monitor"),

    # --- overview grid size -------------------------------------------------
    # The grid is fixed at Config's rows x columns because Hyprland numbers
    # workspaces 1..N whether or not they exist. KWin has a real, usually
    # small, list of virtual desktops, so the default 5x2 draws ten cells for
    # one desktop and the launcher is mostly empty boxes. Follow the desktops
    # that actually exist instead. These three rules run in order: the two
    # renames first, then the definitions that still read Config.
    ("modules/ii/overview/OverviewWidget.qml",
     "Config.options.overview.rows", "root.overviewRows"),
    ("modules/ii/overview/OverviewWidget.qml",
     "Config.options.overview.columns", "root.overviewColumns"),
    ("modules/ii/overview/OverviewWidget.qml",
     "    readonly property int workspacesShown: root.overviewRows * root.overviewColumns",
     """    readonly property int overviewColumns: WM.compositor === "hyprland"
        ? Config.options.overview.columns
        : Math.max(1, Math.min(Config.options.overview.columns, WM.workspaces.length))
    readonly property int overviewRows: WM.compositor === "hyprland"
        ? Config.options.overview.rows
        : Math.max(1, Math.ceil(WM.workspaces.length / root.overviewColumns))
    readonly property int workspacesShown: root.overviewRows * root.overviewColumns"""),

    # --- popup placement ----------------------------------------------------
    # Without a screen the PanelWindow lands on whichever one Quickshell picks
    # first, so hovering a widget on the second monitor opened its popup on the
    # first. Follow the hovered widget's own window.
    ("modules/common/widgets/StyledPopup.qml",
     "        anchors.left: root.barEdge",
     "        screen: root.hoverTarget?.QsWindow?.screen ?? null\n"
     "        anchors.left: root.barEdge"),

    # --- screenshots --------------------------------------------------------
    # grim speaks wlr-screencopy, which KWin does not implement, so every
    # screenshot path silently produced nothing: the region selector cropped a
    # file that was never written, and neither copied nor saved anything.
    # org.kde.KWin.ScreenShot2 does the same job per named output. The
    # geometry goes along because stock KWin refuses that call to anything
    # without a declared desktop entry, and the spectacle fallback then has
    # to crop the whole workspace down to this screen.
    ("modules/common/utils/TempScreenshotProcess.qml",
     """    command: ["bash", "-c", `mkdir -p '${StringUtils.shellSingleQuoteEscape(screenshotDir)}' && grim -o '${StringUtils.shellSingleQuoteEscape(screen.name)}' '${StringUtils.shellSingleQuoteEscape(screenshotPath)}'`]""",
     """    readonly property string captureCommand: WM.compositor === "hyprland"
        ? `grim -o '${StringUtils.shellSingleQuoteEscape(screen.name)}' '${StringUtils.shellSingleQuoteEscape(screenshotPath)}'`
        : `mmsimpulse-screenshot '${StringUtils.shellSingleQuoteEscape(screen.name)}' '${StringUtils.shellSingleQuoteEscape(screenshotPath)}' ${screen.x},${screen.y},${screen.width},${screen.height}`
    command: ["bash", "-c", `mkdir -p '${StringUtils.shellSingleQuoteEscape(screenshotDir)}' && ${captureCommand}`]"""),

    # The quick paths bypass the shell's own selector and shell out to
    # grim+slurp. spectacle brings its own region UI and is what KDE ships.
    ("modules/ii/regionSelector/RegionSelector.qml",
     """const cmd = `mkdir -p '${saveDir}' && filePath="${saveDir}/screenshot-$(date '+%Y-%m-%d_%H.%M.%S').png" && grim -g "$(slurp)" "$filePath" && cat "$filePath" | wl-copy && notify-send "Screenshot Saved" "Saved to $filePath" -a "Screen Snip" -i "image-x-generic"`;""",
     """const capture = WM.compositor === "hyprland"
                    ? `grim -g "$(slurp)" "$filePath"`
                    : `spectacle -r -b -n -o "$filePath"`;
                const cmd = `mkdir -p '${saveDir}' && filePath="${saveDir}/screenshot-$(date '+%Y-%m-%d_%H.%M.%S').png" && ${capture} && cat "$filePath" | wl-copy && notify-send "Screenshot Saved" "Saved to $filePath" -a "Screen Snip" -i "image-x-generic"`;"""),
    ("modules/ii/regionSelector/RegionSelector.qml",
     """const cmd = `grim -g "$(slurp)" - | wl-copy && notify-send "Screenshot Copied" "Copied to clipboard" -a "Screen Snip" -i "image-x-generic"`;""",
     """const cmd = WM.compositor === "hyprland"
                    ? `grim -g "$(slurp)" - | wl-copy && notify-send "Screenshot Copied" "Copied to clipboard" -a "Screen Snip" -i "image-x-generic"`
                    : `spectacle -r -b -n -c && notify-send "Screenshot Copied" "Copied to clipboard" -a "Screen Snip" -i "image-x-generic"`;"""),
    ("services/Brightness.qml",
     """+ ` && grim -o '${StringUtils.shellSingleQuoteEscape(screenScope.screenName)}' -`""",
     """+ ` && ${WM.compositor === "hyprland" ? "grim -o" : "mmsimpulse-screenshot"} '${StringUtils.shellSingleQuoteEscape(screenScope.screenName)}' -`
                    + `${WM.compositor === "hyprland" ? "" : ` ${screenScope.modelData.x},${screenScope.modelData.y},${screenScope.modelData.width},${screenScope.modelData.height}`}`"""),

    # --- region selector ----------------------------------------------------
    # The region snapping helper shells out to hyprctl and to a python venv the
    # illogical-impulse packages provide. Neither is here: the script fails, its
    # output is empty, and JSON.parse throws on every snip. Snapping is a
    # convenience — the selector works freehand without it — so ask for window
    # regions only where hyprctl exists, and treat unusable output as "nothing
    # to snap to" instead of an exception.
    ("modules/ii/regionSelector/RegionSelection.qml",
     """            + `--hyprctl ` """,
     """            + (WM.compositor === "hyprland" ? `--hyprctl ` : ``) """),
    ("modules/ii/regionSelector/RegionSelection.qml",
     """            onStreamFinished: {
                imageRegions = RegionFunctions.filterImageRegions(
                    JSON.parse(imageDimensionCollector.text),
                    root.windowRegions
                );
            }""",
     """            onStreamFinished: {
                const found = imageDimensionCollector.text.trim();
                if (found.length === 0)
                    return;
                try {
                    imageRegions = RegionFunctions.filterImageRegions(
                        JSON.parse(found),
                        root.windowRegions
                    );
                } catch (error) {
                    console.log("[Region Selector] no snappable regions:", error);
                }
            }"""),

    # --- dismiss a panel when the click went elsewhere ------------------------
    # hyprland-focus-grab-v1 is what closes these panels on Hyprland, and KWin
    # implements nothing like it, so the shell disables the grab there and the
    # panels then stay open until Escape or the key that opened them. What KWin
    # does report is which window holds focus, and a panel losing the user to
    # another window is the case people actually hit. Layer surfaces are not in
    # that list, so opening a panel cannot trip it.
    #
    # ponytail: a click on bare desktop focuses nothing and so does not dismiss.
    # Covering that needs an input surface beneath the panels, which is a change
    # to the panels rather than to this singleton.
    ("services/GlobalFocusGrab.qml",
     """    HyprlandFocusGrab {
        id: grab""",
     """    property string lastFocused: ""

    Connections {
        target: WM
        enabled: WM.compositor !== "hyprland"
        function onWindowListChanged() {
            const now = WM.windowList.find(w => w.focused)?.address ?? "";
            if (now === root.lastFocused)
                return;
            root.lastFocused = now;
            if (now !== "" && root.dismissable.length > 0)
                root.dismiss();
        }
    }

    HyprlandFocusGrab {
        id: grab"""),

    # A Flow only wraps inside a width it was given, and with a label present this
    # was handed none -- every selection row ran off the edge of the page in one
    # line. Every setting that offers a choice goes through here.
    ("modules/common/widgets/ConfigSelectionArray.qml",
     """        Layout.fillWidth: !root.text""",
     """        Layout.fillWidth: true"""),

    # Offering a program that is not installed gives a button that does nothing
    # when pressed and says nothing about why.
    ("modules/ii/settings/pages/ServicesConfig.qml",
     """import qs.modules.common.widgets
""",
     """import qs.modules.common.widgets
import Quickshell.Io
"""),

    ("modules/ii/settings/pages/ServicesConfig.qml",
     """ContentPage {
    id: page
    forceWidth: true
    bottomContentPadding: 15
""",
     """ContentPage {
    id: page
    forceWidth: true
    bottomContentPadding: 15

    property var installedTools: []
    Process {
        running: true
        command: ["bash", "-c",
            "for t in spectacle flameshot gpu-screen-recorder obs; do command -v  >/dev/null && echo ; done"]
        stdout: StdioCollector {
            onStreamFinished: page.installedTools = text.trim().split("\n").filter(t => t.length > 0)
        }
    }
    function availableTools(list) {
        // "shell" is the shell's own selector, which needs nothing installed.
        return list.filter(o => o.value === "shell" || page.installedTools.includes(o.value));
    }
"""),

    # --- hug the bar when something is fullscreen -----------------------------
    # A gapped bar around a fullscreen window shows desktop down the sides of
    # it, which is the case this exists for. Hug has no gap, so the bar stops
    # framing anything the moment a window takes the screen.
    #
    # Every corner-style read in the bar goes through one value now: twenty-five
    # call sites each deciding for themselves is how a per-monitor condition
    # gets forgotten at half of them. The bulk rewrites come first and the
    # declarations after, because the declarations are the one place that still
    # has to name the setting itself.
    ("modules/ii/bar/Bar.qml",
     """Config.options.bar.cornerStyle""",
     """barRoot.effectiveCornerStyle"""),

    ("modules/common/Config.qml",
     """                property int cornerStyle: 0 // 0: Hug | 1: Float | 2: Plain rectangle""",
     """                property int cornerStyle: 0 // 0: Hug | 1: Float | 2: Plain rectangle
                property bool hugWhenFullscreen: true"""),

    # HyprlandData is the Hyprland-only source and is empty on KWin, so this read
    # was always false there and the bar never noticed a fullscreen window at
    # all. WM is the facade both compositors answer through.
    ("modules/ii/bar/Bar.qml",
     """property bool monitorHasFullscreen: HyprlandData.workspaceById[thisMonitorData?.activeWorkspace?.id]?.hasfullscreen ?? false""",
     """property bool monitorHasFullscreen: WM.monitorHasFullscreen(barRoot.screen?.name)"""),

    # Hyprland's workspaces already belong to one monitor, so there the workspace
    # flag is the per-monitor answer. KWin's desktops are global and it is not.
    ("services/HyprlandBackend.qml",
     """    function activeWorkspaceForMonitor(monitorName) {""",
     """    function monitorHasFullscreen(monitorName) {
        return root.activeWorkspaceForMonitor(monitorName)?.hasfullscreen ?? false;
    }

    function activeWorkspaceForMonitor(monitorName) {"""),

    ("modules/ii/bar/Bar.qml",
     """                property bool monitorHasSpecialOpen:""",
     """                property bool monitorHasMaximized: WM.monitorHasMaximized(barRoot.screen?.name)
                // Maximised is the case this is for. A fullscreen window covers the
                // bar outright, so nothing it does there is visible; a maximised one
                // stops at the bar, and a gapped design then shows desktop all
                // around it -- which is the view being complained about.
                property int effectiveCornerStyle: (Config.options.bar.hugWhenFullscreen
                        && (barRoot.monitorHasFullscreen || barRoot.monitorHasMaximized))
                    ? 0 : Config.options.bar.cornerStyle
                property bool monitorHasSpecialOpen:"""),

    ("services/HyprlandBackend.qml",
     """    function monitorHasFullscreen(monitorName) {""",
     """    // Hyprland reports maximised as a fullscreen mode rather than a state of
    // its own, so there is nothing separate to answer with here.
    function monitorHasMaximized(monitorName) {
        return false;
    }

    function monitorHasFullscreen(monitorName) {"""),

    ("modules/ii/bar/Bar.qml",
     """                Component.onCompleted: {
                    GlobalFocusGrab.addPersistent(barRoot);
                }""",
     """                Component.onCompleted: {
                    GlobalFocusGrab.addPersistent(barRoot);
                    // Published once up front as well: the change handler only fires
                    // when the value moves, and a bar that starts hugged would
                    // otherwise never tell its widgets.
                    BarStyle.publish(barRoot.screen?.name, barRoot.effectiveCornerStyle);
                }"""),

    ("modules/ii/bar/Bar.qml",
     """                    ? 0 : Config.options.bar.cornerStyle""",
     """                    ? 0 : Config.options.bar.cornerStyle
                onEffectiveCornerStyleChanged: BarStyle.publish(barRoot.screen?.name, barRoot.effectiveCornerStyle)"""),

    ("modules/ii/bar/BarContent.qml",
     """Item {
    id: root
    implicitHeight: Appearance.sizes.barHeight""",
     """Item {
    id: root
    // Set by the bar, which is what knows whether this monitor has a fullscreen
    // window on it. Falls back to the setting so the component still stands on
    // its own.
    property int cornerStyle: Config.options.bar.cornerStyle
    implicitHeight: Appearance.sizes.barHeight"""),

    ("modules/ii/settings/pages/BarConfig.qml",
     """                    ConfigSelectionArray {
                        text: Translation.tr("Bar style")""",
     """                    ConfigSwitch {
                        text: Translation.tr("Hug when fullscreen")
                        enabled: Config.options.bar.cornerStyle !== 0
                        checked: Config.options.bar.hugWhenFullscreen
                        onCheckedChanged: { Config.options.bar.hugWhenFullscreen = checked; }
                    }
                    ConfigSelectionArray {
                        text: Translation.tr("Bar style")"""),

    # --- which program takes the picture -------------------------------------
    # The shell's own selector reads the screen over wlr-screencopy, which KWin
    # does not implement: it froze nothing and saved nothing. Spectacle ships
    # with KDE, does regions and records, and is the default here. The tool is a
    # setting because the right answer differs per machine -- gpu-screen-recorder
    # is far lighter for long captures, OBS is what someone already streaming
    # wants, and the built-in one is correct again on Hyprland.
    ("modules/common/Config.qml",
     """            property JsonObject screenRecord: JsonObject {
                property string savePath: Directories.videos.replace("file://","") // strip "file://"
            }

            property JsonObject screenSnip: JsonObject {
                property string savePath: "" // only copy to clipboard when empty
            }""",
     """            property JsonObject screenRecord: JsonObject {
                property string savePath: Directories.videos.replace("file://","") // strip "file://"
                // spectacle | gpu-screen-recorder | obs | shell
                property string tool: "spectacle"
            }

            property JsonObject screenSnip: JsonObject {
                property string savePath: "" // only copy to clipboard when empty
                // spectacle | flameshot | shell
                property string tool: "spectacle"
            }"""),

    ("modules/ii/regionSelector/RegionSelector.qml",
     """
    function screenshot() {
        if (Persistent.states.record.enable) {""",
     """
    // Which program answers the screenshot and record buttons. The shell's own
    // selector stays available as "shell" but is not the default: its frozen
    // frame and its recorder both read the screen over wlr-screencopy, which
    // KWin does not implement, so on KDE they show and save nothing.
    function snipCommand() {
        const dir = Config.options.screenSnip.savePath;
        switch (Config.options.screenSnip.tool) {
        case "shell":
            return "";
        case "flameshot":
            return dir !== "" ? `flameshot gui -p '${dir}'` : `flameshot gui -c`;
        default:
            // Save and copy in one press, which is the whole point of a quick
            // screenshot. spectacle's own -c goes through a clipboard helper
            // that never starts without plasmashell -- it silently leaves the
            // clipboard empty here -- so the file goes through wl-copy instead.
            return dir !== ""
                ? `mkdir -p '${dir}' && f='${dir}/screenshot-'$(date '+%Y-%m-%d_%H.%M.%S')'.png' && spectacle -r -b -n -o "$f" && wl-copy --type image/png < "$f" && notify-send "Screenshot" "Saved and copied" -a "Screen Snip" -i "$f"`
                : `f=$(mktemp --suffix=.png) && spectacle -r -b -n -o "$f" && wl-copy --type image/png < "$f" && rm -f "$f" && notify-send "Screenshot" "Copied to clipboard" -a "Screen Snip" -i "image-x-generic"`;
        }
    }

    function recordCommand(withSound) {
        const dir = Config.options.screenRecord.savePath;
        switch (Config.options.screenRecord.tool) {
        case "shell":
            return "";
        case "gpu-screen-recorder":
            // -w portal, because KWin exposes no window id the recorder can read
            // directly; the portal picker is how it gets a source here.
            return `mkdir -p '${dir}' && gpu-screen-recorder -w portal -f 60${withSound ? " -a default_output" : ""} -o '${dir}/recording-$(date '+%Y-%m-%d_%H.%M.%S').mp4'`;
        case "obs":
            return "obs --startrecording --minimize-to-tray";
        default:
            // Spectacle keeps its own stop control, so nothing here has to track
            // whether a recording is running.
            return "spectacle -R region";
        }
    }

    function screenshot() {
        const external = root.snipCommand();
        if (external !== "") {
            Quickshell.execDetached(["bash", "-c", external]);
            return;
        }
        if (Persistent.states.record.enable) {"""),

    ("modules/ii/regionSelector/RegionSelector.qml",
     """
    function record() {
        if (Persistent.states.record.enable) {""",
     """
    function record() {
        const external = root.recordCommand(false);
        if (external !== "") {
            Quickshell.execDetached(["bash", "-c", external]);
            return;
        }
        if (Persistent.states.record.enable) {"""),

    ("modules/ii/regionSelector/RegionSelector.qml",
     """
    function recordWithSound() {
        if (Persistent.states.record.enable) {""",
     """
    function recordWithSound() {
        const external = root.recordCommand(true);
        if (external !== "") {
            Quickshell.execDetached(["bash", "-c", external]);
            return;
        }
        if (Persistent.states.record.enable) {"""),

    # The setting has to be reachable, so it sits with the save paths it belongs
    # beside rather than in a corner of its own.
    ("modules/ii/settings/pages/ServicesConfig.qml",
     """            GroupedList {
                ConfigTextArea {
                    id: videoRecordPathField""",
     """            GroupedList {
                ConfigSelectionArray {
                    text: Translation.tr("Screenshot tool")
                    icon: "screenshot_monitor"
                    currentValue: Config.options.screenSnip.tool
                    onSelected: newValue => { Config.options.screenSnip.tool = newValue; }
                    options: page.availableTools([
                        { displayName: Translation.tr("Spectacle"), icon: "photo_camera", value: "spectacle" },
                        { displayName: Translation.tr("Flameshot"), icon: "brush", value: "flameshot" },
                        { displayName: Translation.tr("Built-in"), icon: "crop", value: "shell" }
                    ])
                }

                ConfigSelectionArray {
                    text: Translation.tr("Screen recorder")
                    icon: "videocam"
                    currentValue: Config.options.screenRecord.tool
                    onSelected: newValue => { Config.options.screenRecord.tool = newValue; }
                    options: page.availableTools([
                        { displayName: Translation.tr("Spectacle"), icon: "photo_camera", value: "spectacle" },
                        { displayName: Translation.tr("GPU Screen Recorder"), icon: "memory", value: "gpu-screen-recorder" },
                        { displayName: Translation.tr("OBS"), icon: "cast", value: "obs" },
                        { displayName: Translation.tr("Built-in"), icon: "crop", value: "shell" }
                    ])
                }

                ConfigTextArea {
                    id: videoRecordPathField"""),

    # --- tray menu: scroll a menu taller than the screen ----------------------
    # Nothing clamped the popup and nothing scrolled inside it, so an app with
    # more entries than the screen is tall put the rest below the bottom edge
    # with no way to reach them. The window stops at the screen and the content
    # flicks, using the shell's own scroll widget so the wheel behaves the way
    # it does everywhere else here.
    ("modules/ii/bar/SysTrayMenu.qml",
     """        return result + popupBackground.padding * 2 + root.padding * 2;""",
     """        const wanted = result + popupBackground.padding * 2 + root.padding * 2;
        // Nothing assigns `screen` on this popup, so the height comes from the
        // window it is anchored to -- the bar, which is on the screen the menu
        // will appear on.
        const tall = root.anchor?.window?.screen?.height ?? root.screen?.height ?? 0;
        return tall > 0 ? Math.min(wanted, tall - root.padding * 4) : wanted;"""),

    ("modules/ii/bar/SysTrayMenu.qml",
     """            implicitHeight: stackView.implicitHeight + popupBackground.padding * 2""",
     """            // Follows the window once the window itself has hit the screen.
            implicitHeight: Math.min(stackView.implicitHeight + popupBackground.padding * 2,
                                     root.implicitHeight - root.padding * 2)"""),

    ("modules/ii/bar/SysTrayMenu.qml",
     """            StackView {
                id: stackView
                anchors {
                    fill: parent
                    margins: popupBackground.padding
                }""",
     """            StyledFlickable {
                id: scroller
                anchors {
                    fill: parent
                    margins: popupBackground.padding
                }
                contentWidth: width
                contentHeight: stackView.implicitHeight
                // Only takes the wheel when there is something to scroll, so a
                // short menu still passes it through to whatever is underneath.
                interactive: contentHeight > height
                clip: true

            StackView {
                id: stackView
                width: scroller.width
                height: stackView.implicitHeight"""),

    ("modules/ii/bar/SysTrayMenu.qml",
     """                initialItem: SubMenu {
                    handle: root.trayItemMenuHandle
                }
            }
        }""",
     """                initialItem: SubMenu {
                    handle: root.trayItemMenuHandle
                }
            }
            }
        }"""),

    # --- tray menu: open only once there is something to show ----------------
    # The popup is created and opened in the same frame, before the tray app has
    # answered with its menu. A menu that arrives afterwards resizes the window,
    # but the Wayland surface keeps the buffer it was mapped with, so the
    # compositor stretches that first tiny frame — a blurry, giant "Unpin" with
    # the real rows laid out underneath it, clickable but never repainted.
    #
    # Steam hits this every time: it rebuilds its menu constantly (revision 1100
    # against Discord's 3), so its sixteen entries always land after the map.
    # Discord's are already there, which is why only Steam looked broken.
    #
    # Waiting for a non-zero entry count fixed Steam and nothing else. An app
    # that answers in stages -- one entry, then the rest a frame later -- is
    # mapped on the first one and resized after it, which is the same bug with
    # a different app's name on it. Wait for the count to stop changing.
    ("modules/ii/bar/SysTrayMenu.qml",
     """    function open() {
        root.visible = true;
        root.menuOpened(root);
    }""",
     """    QsMenuOpener {
        id: rootOpener
        menu: root.trayItemMenuHandle
    }

    property bool wantOpen: false
    // Set once waiting has gone on long enough to stop being worth it.
    property bool doneWaiting: false
    readonly property int entryCount: rootOpener.children.values.length

    // Every change restarts the wait: an app that sends its menu in stages must
    // not be mapped between them.
    onEntryCountChanged: settle.restart()

    function open() {
        root.wantOpen = true;
        settle.restart();
    }

    function showIfReady() {
        if (!root.wantOpen || root.visible)
            return;
        if (root.entryCount === 0 && !root.doneWaiting)
            return;
        root.visible = true;
        root.menuOpened(root);
    }

    // Short enough that a menu already in hand still feels instant, long enough
    // to bridge the gap between one app's two answers.
    Timer {
        id: settle
        interval: 80
        onTriggered: root.showIfReady()
    }

    // An app whose menu is genuinely empty, or one that never answers, still has
    // to open — otherwise right-clicking it would do nothing at all.
    Timer {
        interval: 300
        running: root.wantOpen && !root.visible
        onTriggered: {
            root.doneWaiting = true;
            root.showIfReady();
        }
    }"""),

    # --- tray menu ----------------------------------------------------------
    # The rows of a tray menu know their own size, but the ColumnLayout holding
    # them reports none of it here, so the popup ends up 28x37 — the size of its
    # own padding — and right-clicking a tray icon appears to do nothing.
    # Measuring the rows gives the window a real size.
    ("modules/ii/bar/SysTrayMenu.qml",
     """    component SubMenu: ColumnLayout {
        id: submenu
        required property QsMenuHandle handle
        property bool isSubMenu: false
        property bool shown: false
        opacity: shown ? 1 : 0""",
     """    component SubMenu: ColumnLayout {
        id: submenu
        required property QsMenuHandle handle
        property bool isSubMenu: false
        property bool shown: false
        opacity: shown ? 1 : 0

        implicitWidth: {
            menuEntriesRepeater.count;
            let w = 0;
            for (let i = 0; i < submenu.children.length; i++) {
                const child = submenu.children[i];
                if (child.visible)
                    w = Math.max(w, child.implicitWidth);
            }
            return w;
        }
        implicitHeight: {
            menuEntriesRepeater.count;
            let h = 0;
            for (let i = 0; i < submenu.children.length; i++) {
                const child = submenu.children[i];
                if (child.visible)
                    h += child.implicitHeight;
            }
            return h;
        }"""),

    # --- taskbar ------------------------------------------------------------
    # Same ToplevelManager gap as the overview: the dock's list of running apps
    # comes out empty on KWin. The dock only needs appId, activated and
    # activate() from each entry, so hand it stand-ins built from the window
    # list.
    ("services/TaskbarApps.qml",
     "        for (const toplevel of ToplevelManager.toplevels.values) {",
     """        const liveToplevels = WM.compositor === "hyprland"
            ? ToplevelManager.toplevels.values
            : WM.windowList.map(w => ({
                appId: w.class ?? "",
                activated: w.focused ?? false,
                address: w.address
            }));
        for (const toplevel of liveToplevels) {"""),

    # The stand-ins carry an address rather than an activate() method: they go
    # through a `list<var>` property on the way to the dock, and a plain data
    # object survives that trip where a closure is not worth betting on.
    ("modules/ii/bar/DocktoPanel.qml",
     "                        entry.toplevels[next].activate()",
     """                            const target = entry.toplevels[next]
                            if (WM.compositor === "hyprland") target.activate()
                            else WM.focusWindow(target.address)"""),
    ("modules/ii/bar/DocktoPanel.qml",
     "                            activeSlot.modelData.toplevels[next].activate()",
     """                            const target = activeSlot.modelData.toplevels[next]
                            if (WM.compositor === "hyprland") target.activate()
                            else WM.focusWindow(target.address)"""),

    # --- wallpaper picker ----------------------------------------------------
    # A tab of its own rather than a page in the wallpaper selector: the
    # selector only knows how to set a still image, and every animated source
    # here needs a player started and stopped instead.
    ("modules/ii/sidebarLeft/SidebarLeftContent.qml",
     """        ...((root.animeEnabled && !root.animeCloset) ? [{"icon": "bookmark_heart", "name": Translation.tr("Anime")}] : [])
    ]""",
     """        ...((root.animeEnabled && !root.animeCloset) ? [{"icon": "bookmark_heart", "name": Translation.tr("Anime")}] : []),
        {"icon": "wallpaper", "name": Translation.tr("Wallpapers")}
    ]"""),

    # The placeholder page goes with it. It stood in for an empty sidebar, and
    # with a tab that is always present there is no empty sidebar left — while
    # leaving it would put a page in front of the wallpaper one and hand every
    # tab after it the wrong page.
    ("modules/ii/sidebarLeft/SidebarLeftContent.qml",
     """                    ...((root.tabButtonList.length === 0 || (!root.aiChatEnabled && !root.translatorEnabled && root.animeCloset)) ? [placeholder.createObject()] : []),
                    ...(root.animeEnabled ? [anime.createObject()] : []),
                ]""",
     """                    ...(root.animeEnabled ? [anime.createObject()] : []),
                    wallpapers.createObject(),
                ]"""),

    ("modules/ii/sidebarLeft/SidebarLeftContent.qml",
     """        Component {
            id: placeholder
            Item {
                StyledText {
                    anchors.centerIn: parent
                    text: root.animeCloset ? Translation.tr("Nothing") : Translation.tr("Enjoy your empty sidebar...")
                    color: Appearance.colors.colSubtext
                }
            }
        }""",
     """        Component {
            id: wallpapers
            WallpaperPicker {}
        }"""),

    # --- launcher actions ---------------------------------------------------
    ("services/LauncherSearch.qml",
     'Hyprland.dispatch("global quickshell:wallpaperSelectorToggle")',
     'GlobalStates.wallpaperSelectorOpen = !GlobalStates.wallpaperSelectorOpen'),

    # --- session ------------------------------------------------------------
    # loginctl lock-session needs a lock handler, which without plasmashell is
    # this shell itself; -p keeps it pointed at whichever config is running.
    ("modules/common/functions/Session.qml",
     '        if (WM.compositor === "niri") {\n'
     '            Quickshell.execDetached(["qs", "-c", "end4-pC", "ipc", "call", "lock", "activate"]);\n'
     '        } else {\n'
     '            Quickshell.execDetached(["loginctl", "lock-session"]);\n'
     '        }',
     '        if (WM.compositor === "hyprland") {\n'
     '            Quickshell.execDetached(["loginctl", "lock-session"]);\n'
     '        } else {\n'
     '            Quickshell.execDetached(["qs", "-p", Quickshell.shellPath(""), "ipc", "call", "lock", "activate"]);\n'
     '        }'),
    # `pkill -i Hyprland` obviously does nothing here. Ending the logind
    # session is the documented way out; killing the compositor is the
    # fallback, and start-mmsimpulse exits when it dies.
    ("modules/common/functions/Session.qml",
     '        if (WM.compositor === "niri") {\n'
     '            Quickshell.execDetached(["niri", "msg", "action", "quit"]);\n'
     '        } else {\n'
     '            Quickshell.execDetached(["pkill", "-i", "Hyprland"]);\n'
     '        }',
     '        if (WM.compositor === "niri") {\n'
     '            Quickshell.execDetached(["niri", "msg", "action", "quit"]);\n'
     '        } else if (WM.compositor === "kde") {\n'
     '            Quickshell.execDetached(["bash", "-c",\n'
     '                \'loginctl terminate-session "${XDG_SESSION_ID:-}" || pkill -x kwin_wayland\']);\n'
     '        } else {\n'
     '            Quickshell.execDetached(["pkill", "-i", "Hyprland"]);\n'
     '        }'),
    ("modules/common/functions/Session.qml",
     '        HyprlandData.windowList.map(w => w.pid)',
     '        (WM.compositor === "hyprland" ? HyprlandData.windowList : WM.windowList).map(w => w.pid)'),

    # --- bar popups on the wrong screen -------------------------------------
    # QsWindow is the attached object; the screen hangs off its `window`, which
    # is how BarContent.qml spells it. One level short here means the
    # expression is undefined, the binding falls back to null, and Quickshell
    # puts every bar popup on its default screen — so hovering the battery on
    # one monitor opens its popup on the other. Invisible with one screen.
    ("modules/common/widgets/StyledPopup.qml",
     "        screen: root.hoverTarget?.QsWindow?.screen ?? null",
     "        screen: root.hoverTarget?.QsWindow?.window?.screen ?? null"),

    # Same bug's other half: with the screen wrong, so is the width the popup
    # is clamped into. And clamp the window, not the background inside it —
    # the window is wider by the shadow's elevation margin on both sides, so
    # clamping the inner rectangle lets the surface hang over the edge.
    ("modules/common/widgets/StyledPopup.qml",
     "            const maxLeft = popupWindow.screen.width - popupBackground.implicitWidth - margin - 10",
     "            const maxLeft = popupWindow.screen.width - popupWindow.implicitWidth - 10"),
    ("modules/common/widgets/StyledPopup.qml",
     "            const maxTop = popupWindow.screen.height - popupBackground.implicitHeight - margin - 15",
     "            const maxTop = popupWindow.screen.height - popupWindow.implicitHeight - 15"),

    # --- config location ----------------------------------------------------
    # Own config directory, so mmsimpulse and the Hyprland session stop sharing
    # (and overwriting) each other's settings.
    ("modules/common/Directories.qml",
     '${Directories.config}/illogical-impulse',
     '${Directories.config}/mmsimpulse'),
]

# Hyprland-only cursor tweaks: harmless to keep, but they must not fire on KWin.
# Every bar widget decides for itself whether to draw as a Material pill, and
# each one read the setting directly -- so hugging on maximise changed the bar's
# shell and left twenty widgets still styled as M3. They ask BarStyle now, which
# answers per screen, because one monitor can have a maximised window while the
# other does not.
BAR_STYLE_FILES = [
    "modules/ii/bar/BarContent.qml",
    "modules/ii/bar/BarGroup.qml",
    "modules/ii/bar/BatteryIndicator.qml",
    "modules/ii/bar/Divisor.qml",
    "modules/ii/bar/DocktoPanel.qml",
    "modules/ii/bar/LauncherButton.qml",
    "modules/ii/bar/LeftSidebarButton.qml",
    "modules/ii/bar/Media.qml",
    "modules/ii/bar/NotificationUnreadCount.qml",
    "modules/ii/bar/PowerButton.qml",
    "modules/ii/bar/SysTray.qml",
    "modules/ii/bar/SystemIcons.qml",
    "modules/ii/bar/UpdatesCount.qml",
    "modules/ii/bar/UtilButtons.qml",
    "modules/ii/bar/Visualizer.qml",
    "modules/ii/bar/WeatherBar.qml",
    "modules/ii/bar/Workspaces.qml",
    "modules/common/widgets/BarWidgetSwitcher.qml",
    "modules/common/widgets/BarWidgetSwitcherArea.qml",
]

GUARD = [
    ("modules/ii/sidebarLeft/anime/BooruImage.qml",
     'Hyprland.dispatch("hl.config({cursor = {no_warps = true}})")',
     'if (WM.compositor === "hyprland") Hyprland.dispatch("hl.config({cursor = {no_warps = true}})")'),
    ("modules/ii/sidebarLeft/anime/BooruImage.qml",
     'Hyprland.dispatch("hl.config({cursor = {no_warps = false}})")',
     'if (WM.compositor === "hyprland") Hyprland.dispatch("hl.config({cursor = {no_warps = false}})")'),
]

# WorkspaceModel's non-Hyprland path was written for niri, where every
# workspace names an output. KWin's are global and report none.
WORKSPACE_MODEL = [
    # niri names an output on every workspace; KWin's are global and name none.
    # Which desktop a given monitor is on is the backend's question, because
    # with PerOutputVirtualDesktops each output has its own.
    ("""        const ws = WM.workspaces.find(w => w.output === root.monitorName && w.is_active)
        return ws?.idx ?? 1""",
     """        return WM.activeWorkspaceForMonitor(root.monitorName)?.id ?? 1"""),
    ("w.output === root.monitorName && w.idx === number",
     '(w.output === "" || w.output === root.monitorName) && w.idx === number'),
    # A workspace counts as occupied on this monitor only if it holds a window
    # on this monitor — otherwise every indicator lights up for every screen.
    ("                return WM.windowList.some(w => w.workspaceId === realId)",
     """                return WM.windowList.some(w => w.workspaceId === realId
                    && (!w.output || w.output === root.monitorName))"""),
]

IMPORT = "import qs.services"

# QsWindow is an attached type from Quickshell. A file that never imported it
# leaves root.QsWindow undefined, the binding throws rather than falling back,
# and the widget renders with no colour at all -- which is how this first
# shipped.
NEEDED = (("WM.", IMPORT), ("BarStyle.", IMPORT), ("QsWindow", "import Quickshell"))


def ensure_import(text):
    """Add the imports the rewrites above rely on, where they are missing."""
    for marker, statement in NEEDED:
        if marker not in text or re.search(r"^%s$" % re.escape(statement), text, re.M):
            continue
        imports = list(re.finditer(r"^import .*$", text, re.M))
        if not imports:
            continue
        at = imports[-1].end()
        text = text[:at] + "\n" + statement + text[at:]
    return text


def main():
    root = pathlib.Path(sys.argv[1])
    files = {p.relative_to(root).as_posix(): p
             for pattern in ("*.qml", "*.sh", "*.py")
             for p in root.rglob(pattern)}
    changed = set()
    misses = []

    def apply(rel, old, new, required=True):
        path = files.get(rel)
        if path is None:
            misses.append(f"{rel}: file not found")
            return
        text = path.read_text()
        if old not in text:
            if required:
                misses.append(f"{rel}: pattern not found:\n    {old.splitlines()[0]}")
            return
        path.write_text(text.replace(old, new))
        changed.add(rel)

    for old, new in CONFIG_DIR + GLOBAL:
        hits = 0
        for rel, path in files.items():
            if rel in EXCLUDE:
                continue
            if not rel.endswith(".qml") and (old, new) in GLOBAL:
                continue
            text = path.read_text()
            if old in text:
                path.write_text(text.replace(old, new))
                changed.add(rel)
                hits += 1
        if hits == 0:
            misses.append(f"global rule matched nothing: {old}")

    for rel, old, new in SPECIFIC + GUARD:
        apply(rel, old, new)

    for old, new in WORKSPACE_MODEL:
        apply("modules/common/models/WorkspaceModel.qml", old, new)

    for rel in BAR_STYLE_FILES:
        apply(rel, "Config.options.bar.cornerStyle",
              "BarStyle.corner(root.QsWindow?.window?.screen?.name)")

    for rel in sorted(changed):
        path = files[rel]
        path.write_text(ensure_import(path.read_text()))

    if misses:
        print("patch-shell: the skin has changed under these rules:", file=sys.stderr)
        for m in misses:
            print("  " + m, file=sys.stderr)
        sys.exit(1)

    print(f"patched {len(changed)} files")


if __name__ == "__main__":
    main()
