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
        keepAbove: w.keepAbove === true
    };
}

function push() {
    const windows = workspace.windowList()
        .filter(w => w.normalWindow && !w.skipTaskbar)
        .map(describe);
    callDBus(SERVICE, PATH, IFACE, "Update", JSON.stringify({
        windows: windows,
        activeOutput: workspace.activeScreen ? workspace.activeScreen.name : ""
    }));
}

function track(w) {
    // Deliberately not frameGeometryChanged: it fires every frame of a drag and
    // would flood the bus. interactiveMoveResizeFinished is the settled edge.
    w.captionChanged.connect(push);
    w.desktopsChanged.connect(push);
    w.minimizedChanged.connect(push);
    w.fullScreenChanged.connect(push);
    w.keepAboveChanged.connect(push);
    w.outputChanged.connect(push);
    w.interactiveMoveResizeFinished.connect(push);
}

workspace.windowList().forEach(track);
workspace.windowAdded.connect(w => { track(w); push(); });
workspace.windowRemoved.connect(push);
workspace.windowActivated.connect(push);
workspace.currentDesktopChanged.connect(push);
push();
