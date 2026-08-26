pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

// WM backend for KineticWE (and any KWin 6 session). Same contract as
// NiriBackend.qml, same shape: a long-lived process streams JSON state in,
// commands go out as one-shot calls.
//
// State arrives from mmsimpulse-kwin-bridge rather than from the compositor
// directly because KWin publishes no window list on D-Bus and Quickshell has
// no D-Bus API in QML. See bin/mmsimpulse-kwin-bridge for why.
//
// Tiling is deliberately absent: mmsimpulse runs KineticWE with [Tiling]
// Enabled=false, and WM.qml's contract has no swap/resize/split to implement.
Scope {
    id: root

    property var windowList: []
    property var workspaces: []
    property var workspaceById: ({})
    property var activeWorkspace: null
    property string activeOutput: ""
    property var outputs: []

    // Monitors come from Quickshell itself, which is already compositor
    // agnostic — no need to ask KWin. The `logical` shape matches NiriBackend
    // so downstream consumers do not care which backend is live.
    // Carries both shapes the skin expects: `logical` is niri's, the flat
    // fields are `hyprctl monitors -j`'s. The overview reads the latter.
    readonly property var monitors: Quickshell.screens.map((s, i) => ({
        id: i,
        name: s.name,
        make: s.model ?? "",
        model: s.model ?? "",
        x: s.x,
        y: s.y,
        width: s.width,
        height: s.height,
        // Quickshell's screen geometry is already logical, unlike hyprctl's
        // which is physical pixels plus a scale factor. Reporting the real
        // device pixel ratio here makes the overview apply it twice and blow
        // windows up on any scaled output.
        scale: 1,
        // KWin reports no struts over D-Bus, so the overview draws the whole
        // output including the strip the bar sits on.
        reserved: [0, 0, 0, 0],
        transform: 0,
        activeWorkspace: root.activeWorkspace,
        logical: { x: s.x, y: s.y, width: s.width, height: s.height, scale: 1 }
    }))
    // QML's JS engine has neither Object.fromEntries nor object spread.
    readonly property var windowByAddress: {
        let byAddress = ({});
        for (const w of root.windowList) byAddress[w.address] = w;
        return byAddress;
    }
    readonly property var addresses: root.windowList.map(w => w.address)
    readonly property var focusedMonitor: root.monitors.find(m => m.name === root.activeOutput)
        ?? root.monitors[0] ?? null

    // Everything that acts on a single window goes through the bridge.
    // org.kde.KWin.WindowsRunner would look like the obvious route, but it
    // belongs to the krunner-integration plugin, which a plain KineticWE
    // session does not load — calls to it fail with "No such interface".
    function windowAction(id, action, value) {
        actionProc.command = ["busctl", "--user", "call",
            "org.mmsimpulse.KWin", "/Windows", "org.mmsimpulse.KWin",
            "WindowAction", "sss", String(id), action, String(value ?? "")];
        actionProc.running = true;
    }

    function kwinCall(method) {
        actionProc.command = ["busctl", "--user", "call",
            "org.kde.KWin", "/KWin", "org.kde.KWin", method];
        actionProc.running = true;
    }

    function focusWindow(id) { root.windowAction(id, "activate") }
    function closeWindow(id) { root.windowAction(id, "close") }
    function minimizeWindow(id) { root.windowAction(id, "minimize") }
    function pinWindow(id) { root.windowAction(id, "keepAbove") }

    // Always switch through the output rather than org.kde.KWin's global
    // setCurrentDesktop. With kwinrc [Windows] PerOutputVirtualDesktops on this
    // moves only the focused monitor, the way Hyprland behaves; with it off
    // KWin still moves every output, so one code path covers both.
    function switchWorkspaceOn(monitorName, id) {
        actionProc.command = ["busctl", "--user", "call",
            "org.mmsimpulse.KWin", "/Windows", "org.mmsimpulse.KWin",
            "SetDesktopForOutput", "si", String(monitorName ?? ""), String(id)];
        actionProc.running = true;
    }

    function switchWorkspace(id) {
        root.switchWorkspaceOn(root.focusedMonitor?.name, id);
    }

    function switchWorkspaceRelative(direction) {
        const name = root.focusedMonitor?.name;
        const from = root.activeWorkspaceForMonitor(name)?.id ?? root.activeWorkspace?.id ?? 1;
        const count = root.workspaces.length;
        if (count === 0) return;
        // Wrap, matching KWin's own next/previousDesktop.
        const next = direction === "next"
            ? (from % count) + 1
            : ((from - 2 + count) % count) + 1;
        root.switchWorkspaceOn(name, next);
    }

    function moveWindowToWorkspace(id, wsId) { root.windowAction(id, "move", wsId) }

    function monitorFor(screen) {
        if (!screen) return null;
        return root.monitors.find(m => m.name === screen.name) ?? null;
    }

    function activeWorkspaceForMonitor(monitorName) {
        // Virtual desktops are global unless kwinrc [Windows]
        // PerOutputVirtualDesktops is on, in which case each output reports its
        // own and the KWin script is the only thing that can see it.
        const output = root.outputs.find(o => o.name === monitorName);
        return root.workspaceById[output?.current] ?? root.activeWorkspace;
    }

    function biggestWindowForWorkspace(wsId) {
        const wins = root.windowList.filter(w => w.workspaceId === wsId && !w.minimized);
        if (wins.length === 0) return null;
        return wins.reduce((a, b) => (a.width * a.height >= b.width * b.height ? a : b));
    }

    function fullscreenOnMonitor(monitorName) {
        const current = root.activeWorkspace?.id ?? -1;
        return root.windowList.some(w => w.fullscreen && !w.minimized
            && w.output === monitorName && w.workspaceId === current);
    }

    function monitorGeometry(screen) {
        const m = root.monitorFor(screen);
        if (!m) return { x: 0, y: 0, scale: 1 };
        return { x: m.logical.x, y: m.logical.y, scale: m.logical.scale };
    }

    Process { id: actionProc }

    Process {
        id: bridge
        running: true
        command: ["mmsimpulse-kwin-bridge"]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                if (line.trim().length === 0) return;
                try {
                    const s = JSON.parse(line);
                    // `monitor` is an index into the monitor list, which only
                    // exists on this side.
                    const monIndex = {};
                    root.monitors.forEach((m, i) => monIndex[m.name] = i);
                    root.windowList = s.windows.map(w => Object.assign({}, w, { monitor: monIndex[w.output] ?? 0 }));
                    root.workspaces = s.workspaces;
                    let byId = {};
                    for (const ws of s.workspaces) byId[ws.id] = ws;
                    root.workspaceById = byId;
                    root.activeWorkspace = byId[s.current] ?? null;
                    root.activeOutput = s.activeOutput ?? "";
                    root.outputs = s.outputs ?? [];
                } catch (e) {
                    console.log("[KwinBackend] parse error: " + e);
                }
            }
        }
        stderr: SplitParser {
            splitMarker: "\n"
            onRead: line => console.log("[KwinBackend] " + line)
        }
        onExited: restartTimer.restart()
    }

    Timer { id: restartTimer; interval: 1000; onTriggered: bridge.running = true }
}
