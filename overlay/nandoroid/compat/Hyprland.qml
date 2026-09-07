pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland as Hl

// Stands in for the Quickshell.Hyprland singleton so a shell written against
// Hyprland can run on KWin unchanged.
//
// Shadowing the real module was the first thing tried and does not work:
// Quickshell ships Quickshell.Hyprland from its own qrc (`prefer
// :/qt/qml/Quickshell/Hyprland/`), which wins over anything on
// QML_IMPORT_PATH. So this lives under its own name and patch-nandoroid.py
// rewrites the import line instead.
//
// On Hyprland every member forwards to the real singleton, so one patched copy
// of the shell serves both compositors.
Singleton {
    id: root

    readonly property bool onHyprland:
        ((Quickshell.env("XDG_CURRENT_DESKTOP") ?? "") + " " +
         (Quickshell.env("XDG_SESSION_DESKTOP") ?? "")).toLowerCase().includes("hyprland")

    // Hyprland's dispatch syntax changed in 0.55; the shell asks which one to
    // speak. KWin speaks neither, and the legacy strings are the ones this
    // dispatch() parses, so it answers "not Lua".
    readonly property bool usingLua: root.onHyprland ? Hl.Hyprland.usingLua : false

    // ---------------------------------------------------------------- state

    // The shell reads `.values` off these, which is Quickshell's ObjectModel
    // shape. Plain arrays would break every one of those call sites, so the
    // KWin side wraps its arrays in the same shape.
    readonly property var workspaces: root.onHyprland ? Hl.Hyprland.workspaces : kwinWorkspaces
    readonly property var monitors: root.onHyprland ? Hl.Hyprland.monitors : kwinMonitors
    readonly property var toplevels: root.onHyprland ? Hl.Hyprland.toplevels : kwinToplevels

    readonly property var focusedMonitor: root.onHyprland
        ? Hl.Hyprland.focusedMonitor
        : (backend ? root._monitor(backend.focusedMonitor) : null)

    readonly property var focusedWorkspace: root.onHyprland
        ? Hl.Hyprland.focusedWorkspace
        : (backend ? root._workspace(backend.activeWorkspace) : null)

    readonly property var focusedClient: root.onHyprland
        ? Hl.Hyprland.focusedClient
        : (backend ? (backend.windowList.find(w => w.focused) ?? null) : null)

    function monitorFor(screen) {
        if (root.onHyprland) return Hl.Hyprland.monitorFor(screen);
        if (!screen || !backend) return null;
        return root._monitor(backend.monitorFor(screen));
    }

    // Real Hyprland refreshes its model from the IPC socket on demand. The KWin
    // bridge pushes instead, so there is nothing to pull and these are no-ops
    // rather than errors.
    function refreshWorkspaces() { if (root.onHyprland) Hl.Hyprland.refreshWorkspaces() }
    function refreshMonitors()   { if (root.onHyprland) Hl.Hyprland.refreshMonitors() }
    function refreshToplevels()  { if (root.onHyprland) Hl.Hyprland.refreshToplevels() }

    // ------------------------------------------------------------- dispatch

    // Everything the shell does to the compositor arrives here as a string.
    // Two syntaxes reach it: the legacy `workspace 3` form that
    // services/HyprlandCompat.qml builds, and raw Lua `hl.dsp.*` calls that a
    // few call sites in the overview write out directly regardless of
    // usingLua. Both are parsed, because both show up on KWin.
    function dispatch(cmd) {
        if (root.onHyprland) { Hl.Hyprland.dispatch(cmd); return }
        if (!backend || !cmd) return;

        const text = String(cmd);
        const addr = (text.match(/address:\s*"?(0x[0-9a-fA-F]+)/) ?? [])[1] ?? null;

        // exec first: its payload can contain any of the words below.
        const exec = text.match(/^\s*exec\s+(.+)$/) ?? text.match(/hl\.dsp\.exec_cmd\("(.+)"\)/);
        if (exec) { Quickshell.execDetached(["sh", "-c", exec[1]]); return }

        if (/closewindow|hl\.dsp\.window\.close/.test(text)) {
            if (addr) backend.closeWindow(addr);
            return;
        }

        if (/movetoworkspace|hl\.dsp\.window\.move/.test(text)) {
            // `pixel = ...` is a free-form move; KWin's desktops have no such
            // notion and the shell only uses it while dragging in the overview.
            if (/pixel\s*=|movewindowpixel/.test(text)) return;
            const ws = root._workspaceArg(text);
            if (addr && ws !== null) backend.moveWindowToWorkspace(addr, ws);
            return;
        }

        if (/focuswindow/.test(text) || (/hl\.dsp\.focus/.test(text) && /window\s*=/.test(text))) {
            if (addr) backend.focusWindow(addr);
            return;
        }

        if (/^\s*workspace\s/.test(text) || (/hl\.dsp\.focus/.test(text) && /workspace\s*=/.test(text))) {
            const rel = text.match(/r([+-])(\d+)/);
            if (rel) { backend.switchWorkspaceRelative(rel[1] === "+" ? "next" : "previous"); return }
            const ws = root._workspaceArg(text);
            if (ws !== null) backend.switchWorkspace(ws);
            return;
        }

        // Deliberately unhandled, and silent about it: window swapping, z-order
        // changes and special (scratchpad) workspaces have no KWin equivalent
        // that maps cleanly, and logging would fire on every drag.
    }

    // ------------------------------------------------------------- internals

    function _workspaceArg(text) {
        const lua = text.match(/workspace\s*=\s*"?(?:name:)?(\d+)/);
        if (lua) return parseInt(lua[1]);
        const legacy = text.match(/(?:^\s*workspace|movetoworkspace(?:silent)?)\s+(\d+)/);
        if (legacy) return parseInt(legacy[1]);
        return null;
    }

    // The shell reads `.monitor.name` off a workspace and `.activeWorkspace`
    // off a monitor, so the flat records the bridge sends are reshaped rather
    // than passed through.
    function _workspace(ws) {
        if (!ws) return null;
        return {
            id: ws.id,
            name: ws.name ?? String(ws.id),
            monitor: { name: ws.output ?? root.backend?.activeOutput ?? "" },
            active: ws.id === root.backend?.activeWorkspace?.id
        };
    }

    function _monitor(m) {
        if (!m) return null;
        return {
            id: m.id, name: m.name, x: m.x, y: m.y,
            width: m.width, height: m.height, scale: m.scale,
            transform: m.transform ?? 0,
            activeWorkspace: root._workspace(
                root.backend?.activeWorkspaceForMonitor(m.name) ?? root.backend?.activeWorkspace)
        };
    }

    property var backend: null

    readonly property QtObject kwinWorkspaces: QtObject {
        readonly property var values: (root.backend?.workspaces ?? []).map(w => root._workspace(w))
    }
    readonly property QtObject kwinMonitors: QtObject {
        readonly property var values: (root.backend?.monitors ?? []).map(m => root._monitor(m))
    }
    readonly property QtObject kwinToplevels: QtObject {
        readonly property var values: root.backend?.windowList ?? []
    }

    Component { id: kwinComp; KwinBackend {} }
    Component.onCompleted: if (!root.onHyprland) root.backend = kwinComp.createObject(root)
}
