import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland as Hl
import qs.services

// Closes a panel when the user clicks anywhere outside it.
//
// Hyprland does this with hyprland-focus-grab-v1, and the shell used that type
// directly; KWin implements no such protocol, so on KDE `cleared` never fired
// and every menu stayed open until Escape. Two things stand in for it there:
//
//  - another window taking focus;
//  - a transparent click catcher over the whole screen, on the Top layer so it
//    also takes clicks on the window that was already focused (where no focus
//    change ever comes). Panels are on Top too, and one opened earlier stacks
//    below the catcher, so the catcher's input region has holes where the
//    `holes` windows are: clicks there reach the panel, not the catcher.
//
// Same interface as HyprlandFocusGrab, so call sites only change the type name.
Scope {
    id: root

    property bool active: false
    property list<var> windows: []
    // Windows whose clicks must pass through the catcher: the panels
    // themselves and anything that stays clickable next to them (the bar).
    property list<var> holes: windows
    signal cleared()

    property int catcherLayer: WlrLayer.Top

    readonly property bool onHyprland: WM.compositor === "hyprland"

    Loader {
        active: root.onHyprland
        sourceComponent: Hl.HyprlandFocusGrab {
            active: root.active
            windows: root.windows
            onCleared: root.cleared()
        }
    }

    // --- KWin ---------------------------------------------------------------
    property string lastFocused: ""

    function focusedAddress() {
        return WM.windowList.find(w => w.focused)?.address ?? "";
    }

    // Take the baseline when the grab starts, so the window that was focused
    // before the panel opened does not count as a click elsewhere.
    onActiveChanged: if (active) lastFocused = focusedAddress()

    Connections {
        target: WM
        enabled: !root.onHyprland && root.active
        function onWindowListChanged() {
            const now = root.focusedAddress();
            if (now === root.lastFocused)
                return;
            root.lastFocused = now;
            if (now !== "")
                root.cleared();
        }
    }

    // Where a layer-shell window sits on its screen, from its anchors, margins
    // and size. A window that keeps clear of exclusive zones (a popup under
    // the bar) is pushed past the zones of the `holes` windows on the same edge.
    function rectOf(w, sw, sh, screen) {
        const a = w?.anchors, m = w?.margins;
        if (!a || !m || !(w.width > 0) || !(w.height > 0))
            return null;
        let top = 0, bottom = 0, left = 0, right = 0;
        if (w.exclusionMode !== ExclusionMode.Ignore) {
            for (const o of root.holes) {
                if (o === w || !o?.anchors || (o.screen && o.screen !== screen) || !(o.exclusiveZone > 0))
                    continue;
                const oa = o.anchors;
                if (oa.top && !oa.bottom) top = Math.max(top, o.exclusiveZone);
                else if (oa.bottom && !oa.top) bottom = Math.max(bottom, o.exclusiveZone);
                else if (oa.left && !oa.right) left = Math.max(left, o.exclusiveZone);
                else if (oa.right && !oa.left) right = Math.max(right, o.exclusiveZone);
            }
        }
        const aw = sw - left - right, ah = sh - top - bottom;
        const ww = (a.left && a.right) ? aw - m.left - m.right : w.width;
        const hh = (a.top && a.bottom) ? ah - m.top - m.bottom : w.height;
        const x = left + (a.left ? m.left : a.right ? aw - ww - m.right : (aw - ww) / 2);
        const y = top + (a.top ? m.top : a.bottom ? ah - hh - m.bottom : (ah - hh) / 2);
        return { x: x, y: y, width: ww, height: hh };
    }

    // Created only while a grab is active, one per screen.
    Variants {
        model: (!root.onHyprland && root.active) ? Quickshell.screens : []
        PanelWindow {
            id: catcher
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: root.catcherLayer
            WlrLayershell.namespace: "quickshell:focusCatcher"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            readonly property var holeRects: root.holes
                .filter(w => w && w.visible !== false && (!w.screen || w.screen === catcher.screen))
                .map(w => root.rectOf(w, catcher.width, catcher.height, catcher.screen))
                .filter(r => r)

            mask: Region {
                width: catcher.width
                height: catcher.height
                regions: holeRegions.instances
            }
            Variants {
                id: holeRegions
                model: catcher.holeRects
                Region {
                    required property var modelData
                    intersection: Intersection.Subtract
                    x: modelData.x
                    y: modelData.y
                    width: modelData.width
                    height: modelData.height
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onPressed: root.cleared()
            }
        }
    }
}
