// mmsimpulse: KWin script that publishes the window list.
//
// KWin exposes no window list on D-Bus and Quickshell owns no D-Bus name, so
// this script is the only source of window state. A KWin script's single exit
// from the compositor is callDBus(), so everything goes to the bridge process
// (org.mmsimpulse.KWin), which merges it with virtual-desktop state and prints
// it for the shell.
//
// Nothing here touches tiling: mmsimpulse runs KineticWE with [Tiling]
// Enabled=false, so windows are plain floating toplevels.

const SERVICE = "org.mmsimpulse.KWin";
const PATH = "/Windows";
const IFACE = "org.mmsimpulse.KWin";

function describe(w) {
    return {
        id: String(w.internalId),
        title: w.caption || "",
        appId: w.resourceClass || "",
        resourceName: w.resourceName || "",
        pid: w.pid,
        // Empty means "on all desktops" in KWin, not "on none".
        desktops: (w.desktops || []).map(d => String(d.id)),
        output: w.output ? w.output.name : "",
        x: w.x,
        y: w.y,
        width: w.width,
        height: w.height,
        active: w.active === true,
        minimized: w.minimized === true,
        fullscreen: w.fullScreen === true,
        maximized: isMaximized(w),
        keepAbove: w.keepAbove === true
    };
}

// KWin's scripting API exposes fullScreen but nothing for maximised, so the
// window is compared against the area it would fill if it were. clientArea is
// the supported way to ask that and already accounts for the bar's reserved
// strip, which is the whole point: a maximised window stops at the bar, and a
// gapped bar then shows desktop around it.
function isMaximized(w) {
    try {
        const area = workspace.clientArea(KWin.MaximizeArea, w);
        const g = w.frameGeometry;
        const near = (a, b) => Math.abs(a - b) <= 2;
        return near(g.width, area.width) && near(g.height, area.height)
            && near(g.x, area.x) && near(g.y, area.y);
    } catch (e) {
        return false;
    }
}

function push() {
    const windows = workspace.windowList()
        .filter(w => w.normalWindow && !w.skipTaskbar)
        .map(describe);
    // With PerOutputVirtualDesktops each output has its own current desktop,
    // and org.kde.KWin's `current` property only reports the global one.
    //
    // Guarded because this is the one part of the snapshot that depends on how
    // the engine converts KWin's QList of outputs. If it throws, the window
    // list has to survive: losing per-output desktops is a detail, losing
    // every window is the whole widget.
    let outputs = [];
    try {
        const screens = workspace.screens;
        for (let i = 0; i < screens.length; i++) {
            const desktop = workspace.currentDesktopForScreen(screens[i]);
            outputs.push({
                name: screens[i].name,
                currentDesktop: desktop ? String(desktop.id) : ""
            });
        }
    } catch (e) {
        outputs = [];
    }
    callDBus(SERVICE, PATH, IFACE, "Update", JSON.stringify({
        windows: windows,
        outputs: outputs,
        activeOutput: workspace.activeScreen ? workspace.activeScreen.name : ""
    }));
}

// A KWin script aborts at the first exception with no visible error unless the
// kwin_scripting category is on, so one renamed signal would silently stop all
// window reporting. Connect only what the build actually exposes.
function connectIfPresent(obj, name) {
    const signal = obj[name];
    if (signal && typeof signal.connect === "function") {
        signal.connect(push);
    }
}

function track(w) {
    // Deliberately not frameGeometryChanged: it fires every frame of a drag and
    // would flood the bus. interactiveMoveResizeFinished is the settled edge.
    // maximizedChanged is not in every build, and connectIfPresent skips what is
    // missing; frameGeometryChanged is the fallback that always fires, and
    // maximising is not a drag so it does not flood the way a resize would.
    ["captionChanged", "desktopsChanged", "minimizedChanged", "fullScreenChanged",
     "maximizedChanged", "maximizedModeChanged", "tileChanged",
     "keepAboveChanged", "outputChanged", "interactiveMoveResizeFinished"]
        .forEach(name => connectIfPresent(w, name));
}

// Publish before wiring anything up, so a bad signal name cannot stop the very
// first snapshot from going out.
push();
workspace.windowList().forEach(track);
workspace.windowAdded.connect(w => { track(w); push(); });
workspace.windowRemoved.connect(push);
workspace.windowActivated.connect(push);
workspace.currentDesktopChanged.connect(push);
