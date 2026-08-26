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
                        if (WM.compositor !== "hyprland") return root.windows.filter(inGroup)
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

    # --- plugin widgets -----------------------------------------------------
    # The bar already resolves a layout name to ./<Name>.qml, so a widget only
    # needs a file. Let names listed in pluginWidgets resolve to plugins/<name>/
    # instead, which keeps a plugin out of the skin's own modules: it is a
    # directory you drop in and a name you add, and deleting the directory
    # removes it. Not a plugin system — just the search path.
    ("modules/ii/bar/BarContent.qml",
     """    function getWidgetUrl(name) {
        if (!name) return "";
        let formattedName = name.charAt(0).toUpperCase() + name.slice(1);
        return Qt.resolvedUrl("./" + formattedName + ".qml");
    }""",
     """    function getWidgetUrl(name) {
        if (!name) return "";
        let formattedName = name.charAt(0).toUpperCase() + name.slice(1);
        if ((Config.options.bar.pluginWidgets ?? []).includes(name))
            return Qt.resolvedUrl(`../../../plugins/${name}/${formattedName}.qml`);
        return Qt.resolvedUrl("./" + formattedName + ".qml");
    }"""),
    ("modules/common/Config.qml",
     """                property JsonObject layouts: JsonObject {
                    property list<string> leftLayout: ["launcherButton", "workspaces", "activeWindow"]""",
     """                // Names here resolve to plugins/<name>/ instead of the
                // bar's own modules. Add the name to a layout as well.
                property list<string> pluginWidgets: []
                property JsonObject discordVoice: JsonObject {
                    property bool showChannelName: true
                    property bool hideWhenDisconnected: false
                }

                property JsonObject layouts: JsonObject {
                    property list<string> leftLayout: ["launcherButton", "workspaces", "activeWindow"]"""),

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
                activate: () => WM.focusWindow(w.address)
            }));
        for (const toplevel of liveToplevels) {"""),

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
    ("w.output === root.monitorName && w.is_active",
     '(w.output === "" || w.output === root.monitorName) && w.is_active'),
    ("w.output === root.monitorName && w.idx === number",
     '(w.output === "" || w.output === root.monitorName) && w.idx === number'),
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
    files = {p.relative_to(root).as_posix(): p for p in root.rglob("*.qml")}
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

    for old, new in GLOBAL:
        hits = 0
        for rel, path in files.items():
            if rel in EXCLUDE:
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
