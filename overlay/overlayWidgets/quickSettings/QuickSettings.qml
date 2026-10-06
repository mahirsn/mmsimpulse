pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.models.quickToggles
import qs.modules.common.widgets
import qs.modules.ii.bar
import qs.modules.ii.overlay
import qs.modules.ii.sidebarRight.quickToggles.androidStyle

// The sidebar's own toggles, in a box that stays over a game. Only the ones
// worth reaching without leaving it: Wi-Fi, Bluetooth, mute, silence
// notifications, power profile, night light and the GPU MUX.
StyledOverlayWidget {
    id: root
    title: Translation.tr("Quick settings")

    readonly property int columns: 2
    readonly property real spacing: 6
    readonly property real cellHeight: 56
    readonly property real innerPadding: 6

    // The bar's GPU switch owns the MUX detection and the reboot dialog; this
    // one is never drawn, it only lends them to the toggle below.
    GpuModeButton {
        id: gpu
        visible: false
    }

    NetworkToggle { id: networkToggle }
    BluetoothToggle { id: bluetoothToggle }
    MicToggle { id: micToggle }
    AudioToggle { id: audioToggle }
    NotificationToggle { id: notificationToggle }
    PowerProfilesToggle { id: powerToggle }
    NightLightToggle { id: nightLightToggle }
    QuickToggleModel {
        id: gpuToggle
        name: Translation.tr("GPU")
        icon: "developer_board"
        toggled: gpu.dgpu
        statusText: gpu.dgpu ? "NVIDIA" : Translation.tr("AMD (hybrid)")
        tooltipText: Translation.tr("Which GPU drives the screen | Switching restarts the computer")
        mainAction: () => { gpu.asking = true }
    }

    readonly property var models: [networkToggle]
        .concat(bluetoothToggle.available ? [bluetoothToggle] : [])
        .concat([micToggle, audioToggle, notificationToggle, powerToggle, nightLightToggle])
        .concat(gpu.mode >= 0 ? [gpuToggle] : [])
    readonly property var rows: {
        const out = [];
        for (let i = 0; i < models.length; i += columns)
            out.push(models.slice(i, i + columns));
        return out;
    }

    minimumWidth: 340
    minimumHeight: rows.length * cellHeight + (rows.length - 1) * spacing + innerPadding * 2

    // Where the sidebar opens a dialog, the overlay has a widget for it.
    function openWidget(identifier) {
        if (!Persistent.states.overlay.open.includes(identifier))
            Persistent.states.overlay.open.push(identifier);
    }
    function openMenu(model) {
        if (model === networkToggle) {
            root.openWidget("wifi");
        } else if (model === bluetoothToggle) {
            root.openWidget("bluetooth");
        } else if (model === micToggle || model === audioToggle) {
            Persistent.states.overlay.volumeMixer.tabIndex = (model === micToggle) ? 1 : 0;
            root.openWidget("volumeMixer");
        } else {
            model.mainAction();
        }
    }

    contentItem: OverlayBackground {
        id: contentItem
        radius: root.contentRadius

        Column {
            id: grid
            anchors {
                fill: parent
                margins: root.innerPadding
            }
            spacing: root.spacing

            Repeater {
                model: ScriptModel {
                    values: root.rows
                }
                delegate: ButtonGroup {
                    id: row
                    required property var modelData
                    spacing: root.spacing

                    Repeater {
                        model: row.modelData
                        delegate: AndroidQuickToggleButton {
                            required property var modelData
                            required property int index
                            toggleModel: modelData
                            buttonIndex: index
                            buttonData: ({ type: modelData.name, size: 1 })
                            expandedSize: true
                            cellSize: 1
                            cellSpacing: root.spacing
                            baseCellHeight: root.cellHeight
                            baseCellWidth: (grid.width - root.spacing * (root.columns - 1)) / root.columns
                            onOpenMenu: root.openMenu(modelData)
                        }
                    }
                }
            }
        }
    }
}
