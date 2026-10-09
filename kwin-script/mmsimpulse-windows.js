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

// KWin 6.7 exposes maximizeMode (3: both directions), which is the answer.
// Older builds have nothing for it, so there the window is compared against the
// area it would fill if it were. That comparison chases its own tail: the bar
// hugging changes the area, a maximised window on another desktop is not moved
// to the new area until it is shown, and until then it reads as not maximised.
function isMaximized(w) {
    if (w.maximizeMode !== undefined)
        return w.maximizeMode === 3;
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
                model: screens[i].model || "",
                currentDesktop: desktop ? String(desktop.id) : ""
            });
        }
    } catch (e) {
        outputs = [];
    }
    callDBus(SERVICE, PATH, IFACE, "Update", JSON.stringify({
        windows: windows,
        outputs: outputs,
        // One pool of workspaces across monitors (see below): a workspace's
        // windows are on whichever monitor last showed it.
        pool: poolOn(),
        // The monitor under the mouse: the shell's focused monitor, as in
        // Hyprland. KWin's active output follows the last focused window and
        // can be the other one.
        cursorOutput: cursorScreenName(),
        activeOutput: workspace.activeScreen ? workspace.activeScreen.name : ""
    }));
}

function cursorScreenName() {
    const p = workspace.cursorPos;
    const s = workspace.screens.find(s => {
        const g = s.geometry;
        return p.x >= g.x && p.x < g.x + g.width && p.y >= g.y && p.y < g.y + g.height;
    });
    return s ? s.name : "";
}

// Publish when the mouse crosses to another monitor, not on every movement.
let lastCursorScreen = cursorScreenName();
workspace.cursorPosChanged.connect(() => {
    const name = cursorScreenName();
    if (name !== lastCursorScreen) {
        lastCursorScreen = name;
        push();
    }
});

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

// One pool of workspaces shared by every monitor, the way Hyprland has it.
//
// With [Windows] PerOutputVirtualDesktops each output shows its own desktop,
// but KWin still keeps a window where it is: desktop 3 on the laptop and
// desktop 3 on the monitor are two separate sets of windows. Here a desktop's
// windows go to whichever output shows it, so there is only one workspace 3.
// Asking for a workspace another monitor is showing does not take it from
// there: the focus goes to that monitor instead, as in Hyprland.
//
// Without per-output desktops every output shows the same one, and gathering
// its windows onto one of them would empty the others, so nothing here runs.
function poolOn() {
    return options.perOutputVirtualDesktops === true;
}

// Workspace sharing. Picking "Share virtual screen" in the screen-share dialog
// makes KWin create a screen that exists only in the stream. Its current
// desktop says which workspace is shared, and the mmsimpulse_workspaceshare
// effect paints that workspace's windows on it from the monitor they are on,
// so the workspace stays usable there and keeps streaming while the monitor
// shows another. Such a screen is not a monitor: the pool neither moves
// windows onto it nor swaps workspaces with it.
const SHARE_PREFIX = "Virtual-virtual-xdp-kde-";
let screenNames = workspace.screens.map(s => s.name);

function isShare(screen) {
    return !!screen && screen.name.startsWith(SHARE_PREFIX);
}

function monitors() {
    return workspace.screens.filter(s => !isShare(s));
}

function onlyDesktop(w) {
    const d = w.desktops || [];
    return d.length === 1 ? d[0] : null;
}

// Transients go along with their parent (sendClientToScreen moves them), and
// docks, the desktop and other special windows belong to an output, not to a
// workspace.
function poolable(w) {
    return w.managed && !w.deleted && !w.specialWindow && !w.transient && onlyDesktop(w) !== null;
}

let settling = false;

function showDesktop(desktop, screen) {
    settling = true;
    workspace.setCurrentDesktopForScreen(desktop, screen);
    settling = false;
}

// A desktop no other output is showing, an empty one if there is any, so a
// monitor that comes up does not put a hidden workspace's windows on display.
function freeDesktop(forScreen) {
    const shown = monitors().filter(s => s !== forScreen)
        .map(s => workspace.currentDesktopForScreen(s));
    const free = workspace.desktops.filter(d => !shown.includes(d));
    const used = workspace.windowList().filter(poolable).map(onlyDesktop);
    return free.find(d => !used.includes(d)) || free[0] || null;
}

// Two monitors showing the same desktop. When one asked for it (Meta+N, the
// bar, the overview), it goes back to the desktop it left and the focus moves
// to the monitor that has it. Otherwise (a monitor plugged in, the script
// loading) the active monitor keeps it and the other takes a free one.
function resolveDuplicates(changed, left) {
    const screens = monitors();
    const keep = changed || workspace.activeScreen;
    if (isShare(keep))
        return;
    const want = workspace.currentDesktopForScreen(keep);
    if (changed) {
        const holder = screens.find(s => s !== changed && workspace.currentDesktopForScreen(s) === want);
        if (!holder)
            return;
        const taken = screens.filter(s => s !== changed).map(s => workspace.currentDesktopForScreen(s));
        const back = left && !taken.includes(left) ? left : freeDesktop(changed);
        if (back)
            showDesktop(back, changed);
        // The pointer goes along: Meta+N acts on the monitor under it.
        callDBus("org.kde.KWin", "/MmsimpulsePointer", "org.mmsimpulse.Pointer", "WarpToScreen", holder.name);
        focusScreen(holder);
        return;
    }
    for (let i = 0; i < screens.length; i++) {
        const other = screens[i];
        if (other === keep || workspace.currentDesktopForScreen(other) !== want)
            continue;
        const shown = screens.map(s => workspace.currentDesktopForScreen(s));
        const next = left && left !== want && !shown.includes(left) ? left : freeDesktop(other);
        if (next)
            showDesktop(next, other);
    }
}

// Moving a window that also changes its size waits for the app to answer, and
// an app on a hidden workspace may not answer (Zen and Firefox do not): the
// window stayed on the monitor it was hidden on and never appeared where its
// workspace was shown. It is moved at its own size first, which needs no
// answer, and a maximised one is maximised again once it is there.
function sendToScreen(w, screen) {
    workspace.sendClientToScreen(w, screen);
    if (w.output === screen)
        return;
    const wasMaximized = w.maximizeMode === 3;
    const g = w.frameGeometry;
    const a = screen.geometry;
    w.frameGeometry = {
        x: a.x + Math.max(0, (a.width - g.width) / 2),
        y: a.y + Math.max(0, (a.height - g.height) / 2),
        width: g.width,
        height: g.height
    };
    if (wasMaximized) {
        w.setMaximize(false, false);
        w.setMaximize(true, true);
    }
}

function gather() {
    const screens = monitors();
    for (let i = 0; i < screens.length; i++) {
        const desktop = workspace.currentDesktopForScreen(screens[i]);
        for (const w of workspace.windowList()) {
            if (poolable(w) && onlyDesktop(w) === desktop && w.output !== screens[i])
                sendToScreen(w, screens[i]);
        }
    }
}

function pool(changed, left) {
    if (!poolOn() || settling)
        return;
    const focused = workspace.activeScreen;
    resolveDuplicates(changed, left);
    gather();
    keepFocusOnScreen(focused);
}


// Moving the focused window moves the focus with it, and on a shared screen
// that is a screen nobody can see: keys would go to a window off the monitor,
// and the shell would open its panels there. The focus goes back to the screen
// it was on (KWin only lets a script step through screens, hence the loop).
function keepFocusOnScreen(focused) {
    if (!isShare(workspace.activeScreen))
        return;
    focusScreen(!isShare(focused) && workspace.screens.includes(focused) ? focused : monitors()[0]);
}

function focusScreen(target) {
    const screens = workspace.screens;
    for (let i = 0; target && i < screens.length && workspace.activeScreen !== target; i++)
        workspace.slotSwitchToNextScreen();
}

// KWin also hands the focus to a screen it has just added, a moment after
// announcing it, so the screen that had it is kept until then.
let focusBeforeShare = null;

let screensChangedAt = 0;

function screensChanged() {
    screensChangedAt = Date.now();
    const added = workspace.screens.filter(s => !screenNames.includes(s.name) && isShare(s));
    screenNames = workspace.screens.map(s => s.name);
    // A new shared screen starts on the workspace in front of you.
    const looking = isShare(workspace.activeScreen) ? monitors()[0] : workspace.activeScreen;
    if (poolOn() && looking) {
        for (const s of added)
            showDesktop(workspace.currentDesktopForScreen(looking), s);
    }
    if (added.length > 0)
        focusBeforeShare = looking;
    pool(null, null);
}

workspace.windowActivated.connect(() => {
    const focused = focusBeforeShare;
    focusBeforeShare = null;
    if (focused)
        keepFocusOnScreen(focused);
});

workspace.currentDesktopChanged.connect((previous, current, output) => pool(output, previous));
if (workspace.screensChanged)
    workspace.screensChanged.connect(screensChanged);
if (options.perOutputVirtualDesktopsChanged)
    options.perOutputVirtualDesktopsChanged.connect(() => pool(null, null));

// Fullscreen games stay on screen when another window takes the focus, as in
// Hyprland. GLFW (Minecraft) and SDL games minimise a fullscreen window
// themselves the moment it loses the focus; KWin honours that and the game
// disappears from its monitor. Hyprland has no minimising, so there it stays.
//
// The order of events tells the two apart. The game's own minimising comes
// right after it lost the focus while still shown; minimising it by hand
// (a shortcut, the title bar) marks it minimised before the focus leaves.
// Only the first is undone, without taking the focus back.
const FOCUS_LOSS_MINIMISE_MS = 1000;

function keepFullscreenShown(w) {
    let lostFocusAt = 0;
    connectIfPresentTo(w, "activeChanged", () => {
        lostFocusAt = !w.active && !w.minimized && w.fullScreen ? Date.now() : 0;
    });
    connectIfPresentTo(w, "minimizedChanged", () => {
        if (w.minimized && w.fullScreen && !w.active && !w.deleted
                && lostFocusAt && Date.now() - lostFocusAt < FOCUS_LOSS_MINIMISE_MS) {
            lostFocusAt = 0;
            w.minimized = false;
        }
    });
}

function connectIfPresentTo(obj, name, handler) {
    const signal = obj[name];
    if (signal && typeof signal.connect === "function")
        signal.connect(handler);
}
workspace.windowList().forEach(keepFullscreenShown);
workspace.windowAdded.connect(keepFullscreenShown);

// A window joins the workspace shown on the monitor it is on.
function joinWorkspaceHere(w) {
    if (!poolOn() || !poolable(w) || !w.output || isShare(w.output))
        return;
    const here = workspace.currentDesktopForScreen(w.output);
    if (here && onlyDesktop(w) !== here)
        w.desktops = [here];
}

// KWin gives a new window the workspace of the focused monitor, wherever the
// window then goes: a game that goes fullscreen on the other monitor, or an app
// that reopens where it was, ended up there on a workspace that monitor was not
// showing, hidden, until the pool pulled it back. It joins the workspace of the
// monitor it lands on instead: when it opens, when it moves there in its first
// seconds or when it goes fullscreen there. A monitor coming or going moves
// windows too; those keep their workspace.
const NEW_WINDOW_SETTLE_MS = 3000;

function trackPool(w, isNew) {
    const addedAt = isNew ? Date.now() : 0;
    // Sent to another desktop (Meta+Alt+N): it goes where that desktop is shown.
    w.desktopsChanged.connect(() => pool(null, null));
    // Dragged onto another output: it joins the desktop shown there instead of
    // being pulled back to the one it came from.
    w.interactiveMoveResizeFinished.connect(() => joinWorkspaceHere(w));
    connectIfPresentTo(w, "outputChanged", () => {
        if (Date.now() - screensChangedAt < 1000)
            return;
        if (w.fullScreen || (addedAt && Date.now() - addedAt < NEW_WINDOW_SETTLE_MS))
            joinWorkspaceHere(w);
    });
}
workspace.windowList().forEach(w => trackPool(w, false));
workspace.windowAdded.connect(w => {
    trackPool(w, true);
    joinWorkspaceHere(w);
});
pool(null, null);

// Meta+1..0 and Meta+Ctrl+Left/Right act on the monitor under the mouse, as
// Hyprland's do. KWin's own "Switch to Desktop N" acts on its active output,
// which follows the last activated window rather than the mouse: a window
// focused on the other monitor (one closing, an app raising itself) sent the
// next Meta+N there while the mouse stayed on the laptop.
// install-workspace-keys.sh moves the keys from KWin's actions to these.
function screenUnderCursor() {
    const p = workspace.cursorPos;
    return monitors().find(s => {
        const g = s.geometry;
        return p.x >= g.x && p.x < g.x + g.width && p.y >= g.y && p.y < g.y + g.height;
    }) || workspace.activeScreen;
}

function switchHere(desktop) {
    const screen = screenUnderCursor();
    if (desktop && screen)
        workspace.setCurrentDesktopForScreen(desktop, screen);
}

function stepHere(by) {
    const desktops = workspace.desktops;
    const screen = screenUnderCursor();
    if (!screen || desktops.length === 0)
        return;
    // Workspaces another monitor is showing are stepped over: asking for one
    // only moves the focus there, so stepping would stop at it.
    const taken = monitors().filter(s => s !== screen).map(s => workspace.currentDesktopForScreen(s));
    let i = desktops.indexOf(workspace.currentDesktopForScreen(screen));
    for (let n = 0; n < desktops.length; n++) {
        i = (i + by + desktops.length) % desktops.length;
        if (!taken.includes(desktops[i])) {
            switchHere(desktops[i]);
            return;
        }
    }
}

for (let n = 1; n <= 10; n++) {
    registerShortcut("mmsimpulse: Switch to workspace " + n,
                     "mmsimpulse: Switch to workspace " + n + " on the monitor under the mouse",
                     "", () => switchHere(workspace.desktops.find(d => d.x11DesktopNumber === n)));
}
registerShortcut("mmsimpulse: Previous workspace",
                 "mmsimpulse: Previous workspace on the monitor under the mouse", "", () => stepHere(-1));
registerShortcut("mmsimpulse: Next workspace",
                 "mmsimpulse: Next workspace on the monitor under the mouse", "", () => stepHere(1));

// Super+H: hide the active window from screen sharing and recording (KWin's
// "exclude from capture"), and show it again. Registered here rather than as a
// .desktop shortcut because only a script can reach the window property.
registerShortcut("mmsimpulse: Hide window from screen capture",
                 "mmsimpulse: Hide the active window from screen sharing and recording",
                 "Meta+H", function () {
    const w = workspace.activeWindow;
    if (w)
        w.excludeFromCapture = !w.excludeFromCapture;
});

// Ctrl+Alt+1..6: text consoles, for keyboards whose F-row sends media keys and
// so never produce the Ctrl+Alt+F-keys KWin switches on by itself.
for (let n = 1; n <= 6; n++) {
    registerShortcut("mmsimpulse: Switch to text console " + n,
                     "mmsimpulse: Switch to text console " + n,
                     "Ctrl+Alt+" + n, function () {
        callDBus(SERVICE, PATH, IFACE, "SwitchToConsole", String(n));
    });
}
