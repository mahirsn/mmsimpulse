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

    // Monitors come from Quickshell itself, which is already compositor
    // agnostic — no need to ask KWin. The `logical` shape matches NiriBackend
    // so downstream consumers do not care which backend is live.
    readonly property var monitors: Quickshell.screens.map(s => ({
        name: s.name,
        make: s.model ?? "",
        model: s.model ?? "",
        logical: { x: s.x, y: s.y, width: s.width, height: s.height, scale: s.devicePixelRatio }
    }))
    readonly property var focusedMonitor: root.monitors.find(m => m.name === root.activeOutput)
        ?? root.monitors[0] ?? null

    // WindowsRunner.Run() takes "<action>_<uuid>"; the numbers are the
    // WindowsRunnerAction enum in kwin's krunner-integration plugin.
    readonly property int actionActivate: 0
    readonly property int actionClose: 1
    readonly property int actionMinimize: 2
    readonly property int actionKeepAbove: 6

    function runnerAction(action, id) {
        actionProc.command = ["busctl", "--user", "call",
            "org.kde.KWin", "/WindowsRunner", "org.kde.KWin.WindowsRunner",
            "Run", "ss", `${action}_${id}`, ""];
        actionProc.running = true;
    }

    function kwinCall(method) {
        actionProc.command = ["busctl", "--user", "call",
            "org.kde.KWin", "/KWin", "org.kde.KWin", method];
        actionProc.running = true;
    }

    function focusWindow(id) { root.runnerAction(root.actionActivate, id) }
    function closeWindow(id) { root.runnerAction(root.actionClose, id) }
    function minimizeWindow(id) { root.runnerAction(root.actionMinimize, id) }
    function pinWindow(id) { root.runnerAction(root.actionKeepAbove, id) }

    function switchWorkspace(id) {
        // org.kde.KWin.setCurrentDesktop takes the 1-based index, which is the
        // same numbering the shell uses, so no uuid lookup is needed here.
        actionProc.command = ["busctl", "--user", "call",
            "org.kde.KWin", "/KWin", "org.kde.KWin", "setCurrentDesktop", "i", String(id)];
        actionProc.running = true;
    }

    function switchWorkspaceRelative(direction) {
        root.kwinCall(direction === "next" ? "nextDesktop" : "previousDesktop");
    }

    function moveWindowToWorkspace(id, wsId) {
        // No D-Bus method exists for this, so the bridge runs a one-shot KWin
        // script instead.
        actionProc.command = ["busctl", "--user", "call",
            "org.mmsimpulse.KWin", "/Windows", "org.mmsimpulse.KWin",
            "MoveToDesktop", "si", String(id), String(wsId)];
        actionProc.running = true;
    }

    function monitorFor(screen) {
        if (!screen) return null;
        return root.monitors.find(m => m.name === screen.name) ?? null;
    }

    function activeWorkspaceForMonitor(monitorName) {
        // KWin virtual desktops are global unless perOutputVirtualDesktops is
        // on, so every monitor shows the same active desktop.
        return root.activeWorkspace;
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
                    root.windowList = s.windows;
                    root.workspaces = s.workspaces;
                    let byId = {};
                    for (const ws of s.workspaces) byId[ws.id] = ws;
                    root.workspaceById = byId;
                    root.activeWorkspace = byId[s.current] ?? null;
                    root.activeOutput = s.activeOutput ?? "";
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
