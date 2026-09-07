import QtQuick
import Quickshell.Io
import Quickshell.Hyprland as Hl

// Hyprland hands shortcuts to the shell over hyprland-global-shortcuts-v1.
// KWin has no such protocol, but kglobalacceld can launch a .desktop entry, so
// on KWin the key runs `qs -c <config> ipc call <name> trigger` and lands here
// instead.
//
// ponytail: nothing writes those .desktop entries yet — shortcuts.tsv and
// install-shortcuts.sh name our own shell's actions, not this one's. Until
// they do, the shell's fifteen shortcuts are reachable over `ipc call` but
// bound to no key.
Loader {
    id: root

    property string name: ""
    property string description: ""
    signal pressed()
    signal released()

    sourceComponent: Hyprland.onHyprland ? hyprlandShortcut : kwinShortcut

    Component {
        id: hyprlandShortcut
        Hl.GlobalShortcut {
            name: root.name
            description: root.description
            onPressed: root.pressed()
            onReleased: root.released()
        }
    }

    Component {
        id: kwinShortcut
        IpcHandler {
            // Namespaced: a shortcut and an IPC handler may share a name — the
            // lock screen has both — and the second registration of a target
            // is dropped, silently taking one of them out.
            target: "key_" + root.name
            // kglobalaccel launches a command and has no release event, so both
            // edges fire together. A hold-to-show binding degrades to a toggle.
            function trigger(): void {
                root.pressed();
                root.released();
            }
        }
    }
}
