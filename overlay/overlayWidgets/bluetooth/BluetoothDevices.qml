pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.ii.overlay
import qs.modules.ii.sidebarRight.bluetoothDevices

// The sidebar's Bluetooth dialog, over a game: the adapter, and pairing,
// connecting and forgetting devices.
StyledOverlayWidget {
    id: root
    title: Translation.tr("Bluetooth")
    minimumWidth: 320
    minimumHeight: 240

    // Look for devices only while it is on screen, as the sidebar's dialog does:
    // discovery left running drains the battery and slows the radio down.
    readonly property bool shown: visible && GlobalStates.overlayOpen
    readonly property bool discover: shown && BluetoothStatus.enabled
    function applyDiscover() {
        if (Bluetooth.defaultAdapter)
            Bluetooth.defaultAdapter.discovering = discover;
    }
    onDiscoverChanged: applyDiscover()
    Component.onCompleted: if (discover) applyDiscover()
    Component.onDestruction: {
        if (discover && Bluetooth.defaultAdapter)
            Bluetooth.defaultAdapter.discovering = false;
    }

    contentItem: OverlayBackground {
        id: contentItem
        radius: root.contentRadius

        ColumnLayout {
            anchors {
                fill: parent
                margins: 8
            }
            spacing: 4

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 6
                spacing: 8

                MaterialSymbol {
                    text: BluetoothStatus.connected ? "bluetooth_connected" : BluetoothStatus.enabled ? "bluetooth" : "bluetooth_disabled"
                    iconSize: 22
                    color: Appearance.colors.colOnLayer2
                }
                StyledText {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    color: Appearance.colors.colOnLayer2
                    text: !BluetoothStatus.available ? Translation.tr("No Bluetooth adapter")
                        : !BluetoothStatus.enabled ? Translation.tr("Bluetooth is off")
                        : BluetoothStatus.firstActiveDevice?.name ?? Translation.tr("Not connected")
                }
                RippleButton {
                    id: power
                    visible: BluetoothStatus.available
                    implicitWidth: 36
                    implicitHeight: 36
                    buttonRadius: height / 2
                    toggled: BluetoothStatus.enabled
                    colBackgroundToggled: Appearance.colors.colSecondaryContainer
                    colBackgroundToggledHover: Appearance.colors.colSecondaryContainerHover
                    colRippleToggled: Appearance.colors.colSecondaryContainerActive
                    onClicked: Bluetooth.defaultAdapter.enabled = !BluetoothStatus.enabled
                    contentItem: MaterialSymbol {
                        anchors.centerIn: parent
                        horizontalAlignment: Text.AlignHCenter
                        text: "power_settings_new"
                        iconSize: 20
                        color: power.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer2
                    }
                }
            }

            StyledIndeterminateProgressBar {
                Layout.fillWidth: true
                visible: Bluetooth.defaultAdapter?.discovering ?? false
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                StyledListView {
                    anchors.fill: parent
                    clip: true
                    spacing: 0
                    animateAppearance: false
                    visible: BluetoothStatus.enabled
                    model: ScriptModel {
                        values: BluetoothStatus.friendlyDeviceList
                    }
                    delegate: BluetoothDeviceItem {
                        required property BluetoothDevice modelData
                        device: modelData
                        width: ListView.view.width
                    }
                }

                PagePlaceholder {
                    shown: !BluetoothStatus.enabled
                    icon: "bluetooth_disabled"
                    title: BluetoothStatus.available ? Translation.tr("Bluetooth is off") : Translation.tr("No Bluetooth adapter")
                }
            }
        }
    }
}
