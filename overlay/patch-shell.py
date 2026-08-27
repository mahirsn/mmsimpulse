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

    # --- dock context menu --------------------------------------------------
    # Right-click only toggled the pin, with nothing on screen to say so. It
    # now opens a menu carrying the desktop entry's own actions — the same
    # ones the launcher lists — plus pin and close.
    ("modules/ii/bar/DocktoPanel.qml",
     "                        altAction:         () => { TaskbarApps.togglePin(slotItem.appId) }",
     "                        altAction:         () => { slotMenu.open = !slotMenu.open }\n"
     "\n"
     "                        DockAppMenu {\n"
     "                            id: slotMenu\n"
     "                            anchorItem: slotItem\n"
     "                            appId: slotItem.appId\n"
     "                            desktopEntry: slotItem.deskEntry\n"
     "                            toplevels: slotItem.appEntry?.toplevels ?? []\n"
     "                        }"),

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

    # The tray menu's rows know their own size, but the ColumnLayout holding
    # them reports none, so the popup stays 28x37 — the size of its own padding
    # — and the menu is an empty stub. Measuring the rows gives it a real size.
    # (This is necessary but not sufficient: see TESTING.md, the popup surface
    # still never reaches KWin.)
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
     '                \'loginctl terminate-session "${XDG_SESSION_ID:-}" || pkill -x kinetic-we\']);\n'
     '        } else {\n'
     '            Quickshell.execDetached(["pkill", "-i", "Hyprland"]);\n'
     '        }'),
    ("modules/common/functions/Session.qml",
     '        HyprlandData.windowList.map(w => w.pid)',
     '        (WM.compositor === "hyprland" ? HyprlandData.windowList : WM.windowList).map(w => w.pid)'),

    # --- config location ----------------------------------------------------
    # Own config directory, so mmsimpulse and the Hyprland session stop sharing
    # (and overwriting) each other's settings.
    ("modules/common/Directories.qml",
     '${Directories.config}/illogical-impulse',
     '${Directories.config}/mmsimpulse'),
]

# Hyprland-only cursor tweaks: harmless to keep, but they must not fire on KWin.
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


def ensure_import(text):
    """WM lives in qs.services; a file that gained a WM call may not import it."""
    if IMPORT in text or "WM." not in text:
        return text
    imports = list(re.finditer(r"^import .*$", text, re.M))
    if not imports:
        return text
    at = imports[-1].end()
    return text[:at] + "\n" + IMPORT + text[at:]


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
