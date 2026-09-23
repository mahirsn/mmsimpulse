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
//  - another window taking focus, which is what any click on an app does;
//  - a click on bare desktop, caught by a transparent surface on the Bottom
//    layer. That layer sits above the wallpaper and below every window and
//    every panel, so the surface only ever receives clicks that landed on
//    nothing else -- it cannot swallow a click meant for the panel itself.
//
// Same interface as HyprlandFocusGrab, so call sites only change the type name.
Scope {
    id: root

    property bool active: false
    property list<var> windows: []
    signal cleared()

    // Where the click catcher sits on KWin. Bottom only sees clicks on bare
    // desktop, which is right for panels that are layer surfaces themselves: a
    // catcher above them would swallow their own clicks. A menu is an xdg
    // popup, which KWin stacks above every panel and window, so its catcher can
    // go on Top and also take clicks on windows -- including the one that was
    // already focused, where no focus change ever comes to say the user left.
    property int catcherLayer: WlrLayer.Bottom

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

    // Created only while a grab is active, one per screen.
    Variants {
        model: (!root.onHyprland && root.active) ? Quickshell.screens : []
        PanelWindow {
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: root.catcherLayer
            WlrLayershell.namespace: "quickshell:focusCatcher"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onPressed: root.cleared()
            }
        }
    }
}
