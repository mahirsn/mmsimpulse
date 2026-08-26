import QtQuick
import Quickshell.Hyprland
import Quickshell.Io
import qs.services

// Hyprland delivers shortcuts to the shell over hyprland-global-shortcuts-v1.
// KWin has no such protocol, but KineticWE's embedded kglobalacceld can launch
// a .desktop entry from a shortcut, so on KDE the key runs
// `qs -c mmsimpulse ipc call <name> trigger` and lands here instead.
// shortcuts/install-shortcuts.sh generates one .desktop per name below.
Loader {
    id: root

    property string name: ""
    property string description: ""
    signal pressed()
    signal released()

    active: WM.compositor === "hyprland" || WM.compositor === "kde"
    sourceComponent: WM.compositor === "kde" ? kwinShortcut : hyprlandShortcut

    Component {
        id: hyprlandShortcut
        GlobalShortcut {
            name: root.name
            description: root.description
            onPressed: root.pressed()
            onReleased: root.released()
        }
    }

    Component {
        id: kwinShortcut
        IpcHandler {
            target: root.name
            // kglobalaccel only launches a command; it has no press/release
            // distinction, so both edges fire together.
            function trigger(): void {
                root.pressed();
                root.released();
            }
        }
    }
}
