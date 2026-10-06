pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs
import qs.services
import qs.services.network
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.ii.overlay
import qs.modules.ii.sidebarRight.wifiNetworks

// The sidebar's Wi-Fi dialog, over a game: the radio, the networks in reach,
// and connecting to one, password prompt included.
StyledOverlayWidget {
    id: root
    title: Translation.tr("Wi-Fi")
    minimumWidth: 320
    minimumHeight: 240

    // Scan whenever it comes into view, as the sidebar does when its dialog opens.
    readonly property bool shown: visible && GlobalStates.overlayOpen
    function scan() {
        if (shown && Network.wifiEnabled)
            Network.rescanWifi();
    }
    onShownChanged: scan()
    Component.onCompleted: scan()

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
                    text: Network.materialSymbol
                    iconSize: 22
                    color: Appearance.colors.colOnLayer2
                }
                StyledText {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    color: Appearance.colors.colOnLayer2
                    text: Network.ethernet ? Translation.tr("Ethernet")
                        : !Network.wifiEnabled ? Translation.tr("Wi-Fi is off")
                        : Network.networkName || Translation.tr("Not connected")
                }
                RoundButton {
                    materialSymbol: "refresh"
                    enabled: Network.wifiEnabled && !Network.wifiScanning
                    onClicked: Network.rescanWifi()
                }
                RoundButton {
                    materialSymbol: "power_settings_new"
                    toggled: Network.wifiEnabled
                    onClicked: Network.enableWifi(!Network.wifiEnabled)
                }
            }

            StyledIndeterminateProgressBar {
                Layout.fillWidth: true
                visible: Network.wifiScanning
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    anchors.fill: parent
                    clip: true
                    visible: Network.wifiEnabled
                    model: ScriptModel {
                        values: Network.friendlyWifiNetworks
                    }
                    delegate: WifiNetworkItem {
                        required property WifiAccessPoint modelData
                        wifiNetwork: modelData
                        width: ListView.view.width
                    }
                }

                PagePlaceholder {
                    shown: !Network.wifiEnabled
                    icon: "signal_wifi_off"
                    title: Translation.tr("Wi-Fi is off")
                }
            }
        }
    }

    component RoundButton: RippleButton {
        id: button
        required property string materialSymbol
        implicitWidth: 36
        implicitHeight: 36
        buttonRadius: height / 2
        colBackgroundToggled: Appearance.colors.colSecondaryContainer
        colBackgroundToggledHover: Appearance.colors.colSecondaryContainerHover
        colRippleToggled: Appearance.colors.colSecondaryContainerActive
        contentItem: MaterialSymbol {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            text: button.materialSymbol
            iconSize: 20
            color: button.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer2
            opacity: button.enabled ? 1 : 0.4
        }
    }
}
