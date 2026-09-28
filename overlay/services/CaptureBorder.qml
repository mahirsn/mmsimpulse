import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.modules.common
import qs.services

// A coloured frame on the active window while it is hidden from screen capture
// (Super+H), so the toggle shows which way it went. Only the active window: an
// inactive one is usually partly covered, and a frame drawn on top would cross
// the windows in front of it. The KWin script hides this frame from capture as
// well, recognising it as the dock surface lying exactly on the hidden window.
Scope {
    id: root

    readonly property var target: WM.windowList.find(w => w.focused && w.excludeFromCapture
        && !w.minimized && !w.moving) ?? null
    readonly property int thickness: 3

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: frame
            required property var modelData
            screen: modelData

            readonly property var target: root.target?.output === modelData.name ? root.target : null
            visible: target !== null

            anchors {
                top: true
                left: true
            }
            margins {
                left: (target?.x ?? 0) - modelData.x
                top: (target?.y ?? 0) - modelData.y
            }
            implicitWidth: Math.max(1, target?.width ?? 1)
            implicitHeight: Math.max(1, target?.height ?? 1)

            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "quickshell:captureBorder"
            // Clicks go through to the window underneath.
            mask: Region {}

            Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.width: root.thickness
                border.color: Appearance.colors.colError
                radius: Appearance.rounding.small
            }
        }
    }
}
