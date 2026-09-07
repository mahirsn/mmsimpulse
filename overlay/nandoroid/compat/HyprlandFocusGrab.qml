import QtQuick
import Quickshell.Hyprland as Hl

// hyprland-focus-grab-v1 is what makes a panel close when you click anywhere
// outside it. KWin implements no equivalent — a layer surface there cannot ask
// the compositor to route the next outside click back to it — so on KWin this
// grabs nothing and `cleared` never fires.
//
// ponytail: panels stay open until dismissed by their own means (Escape, the
// key that opened them, or a click on their own scrim). Closing that gap needs
// a full-screen input surface under each panel, which is a change to the panels
// themselves rather than to this shim.
Loader {
    id: root

    property var windows: []
    signal cleared()

    // `active` is Loader's own property, which is the one the shell writes. On
    // KWin there is nothing to load, so it toggles an empty loader.
    sourceComponent: Hyprland.onHyprland ? grabComponent : null

    Component {
        id: grabComponent
        Hl.HyprlandFocusGrab {
            windows: root.windows
            active: true
            onCleared: root.cleared()
        }
    }
}
