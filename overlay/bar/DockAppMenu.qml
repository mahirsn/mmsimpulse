pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.services

// Right-click menu for a dock entry. Upstream has none — the app actions you
// see in the launcher come from the desktop entry, and this shows the same
// ones, plus what only makes sense on a running app.
//
// Not the application's own menu: that one lives on its tray icon, exported
// over D-Bus by the app itself, and there is no way to reach it from here.
Scope {
    id: root

    property Item anchorItem
    property string appId: ""
    property var desktopEntry: null
    property var toplevels: []
    property bool open: false

    readonly property var actions: root.desktopEntry?.actions ?? []
    readonly property bool pinned: TaskbarApps.isPinned?.(root.appId) ?? false

    LazyLoader {
        active: root.open && root.anchorItem

        PopupWindow {
            visible: true
            color: "transparent"
            implicitWidth: menuColumn.implicitWidth + 20
            implicitHeight: menuColumn.implicitHeight + 20

            anchor {
                window: root.anchorItem.QsWindow.window
                item: root.anchorItem
                edges: Edges.Bottom
                gravity: Edges.Bottom
            }

            // Anywhere outside the items dismisses it, the way a menu should.
            MouseArea {
                anchors.fill: parent
                onClicked: root.open = false
            }

            Rectangle {
                anchors.fill: parent
                anchors.margins: 6
                radius: Appearance.rounding.normal
                color: Appearance.colors.colLayer0
                border.color: ColorUtils.transparentize(Appearance.m3colors.m3outline, 0.7)
                border.width: 1

                ColumnLayout {
                    id: menuColumn
                    anchors.fill: parent
                    anchors.margins: 4
                    spacing: 1

                    Repeater {
                        model: root.actions
                        MenuRow {
                            required property var modelData
                            text: modelData.name
                            onTriggered: { modelData.execute(); root.open = false }
                        }
                    }

                    Rectangle {
                        visible: root.actions.length > 0
                        Layout.fillWidth: true
                        Layout.margins: 4
                        implicitHeight: 1
                        color: ColorUtils.transparentize(Appearance.m3colors.m3outline, 0.7)
                    }

                    MenuRow {
                        text: Translation.tr("New window")
                        visible: !!root.desktopEntry
                        onTriggered: { root.desktopEntry.execute(); root.open = false }
                    }
                    MenuRow {
                        text: root.pinned ? Translation.tr("Unpin") : Translation.tr("Pin")
                        onTriggered: { TaskbarApps.togglePin(root.appId); root.open = false }
                    }
                    MenuRow {
                        text: Translation.tr("Close")
                        visible: root.toplevels.length > 0
                        danger: true
                        onTriggered: {
                            for (const t of root.toplevels) {
                                if (WM.compositor === "hyprland") t.close?.();
                                else WM.closeWindow(t.address);
                            }
                            root.open = false;
                        }
                    }
                }
            }
        }
    }

    component MenuRow: Rectangle {
        id: row
        property string text: ""
        property bool danger: false
        signal triggered()

        Layout.fillWidth: true
        implicitWidth: Math.max(160, label.implicitWidth + 24)
        implicitHeight: 30
        radius: Appearance.rounding.small
        color: mouse.containsMouse
            ? ColorUtils.transparentize(Appearance.colors.colLayer1, 0.5)
            : "transparent"

        StyledText {
            id: label
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 10
            text: row.text
            color: row.danger ? Appearance.m3colors.m3error : Appearance.colors.colOnLayer1
            font.pixelSize: Appearance.font.pixelSize.smaller
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: row.triggered()
        }
    }
}
