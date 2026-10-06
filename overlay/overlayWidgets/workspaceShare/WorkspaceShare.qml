pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.ii.overlay

// Share a workspace rather than a screen. Picking "Share virtual screen" in an
// app's screen-share dialog makes KWin add a screen that exists only in the
// stream, and the KWin script hands that screen the windows of whichever
// workspace it shows. This picks the workspace: the app sees it live while you
// carry on with another one.
StyledOverlayWidget {
    id: root
    title: Translation.tr("Share workspace")
    minimumWidth: 300
    minimumHeight: 150

    // How xdg-desktop-portal-kde names the screens it creates for sharing.
    readonly property string sharePrefix: "Virtual-virtual-xdp-kde-"
    readonly property var shares: (WM.backend?.outputs ?? []).filter(o => o.name.startsWith(sharePrefix))

    function appName(output) {
        // The portal appends -1, -2... when one app shares more than one.
        const appId = output.name.slice(root.sharePrefix.length).replace(/-\d+$/, "");
        return DesktopEntries.heuristicLookup(appId)?.name || appId || Translation.tr("Virtual screen");
    }

    contentItem: OverlayBackground {
        id: contentItem
        radius: root.contentRadius

        ColumnLayout {
            anchors {
                fill: parent
                margins: 10
            }
            visible: root.shares.length > 0
            spacing: 10

            // Keyed, because the bridge sends fresh copies with every change and
            // rebuilt buttons drop the click they were in the middle of.
            Repeater {
                model: ScriptModel {
                    values: root.shares
                    objectProp: "name"
                }
                delegate: ColumnLayout {
                    id: share
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 6

                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        color: Appearance.colors.colOnLayer2
                        text: Translation.tr("Shown to %1").arg(root.appName(share.modelData))
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 4
                        Repeater {
                            model: ScriptModel {
                                values: WM.workspaces
                                objectProp: "id"
                            }
                            delegate: RippleButton {
                                id: ws
                                required property var modelData
                                implicitWidth: 34
                                implicitHeight: 34
                                buttonRadius: height / 2
                                toggled: share.modelData.current === ws.modelData.id
                                colBackground: Appearance.colors.colLayer3
                                colBackgroundHover: Appearance.colors.colLayer3Hover
                                colRipple: Appearance.colors.colLayer3Active
                                colBackgroundToggled: Appearance.colors.colPrimary
                                colBackgroundToggledHover: Appearance.colors.colPrimaryHover
                                colRippleToggled: Appearance.colors.colPrimaryActive
                                onClicked: WM.backend.switchWorkspaceOn(share.modelData.name, ws.modelData.id)
                                contentItem: StyledText {
                                    anchors.centerIn: parent
                                    horizontalAlignment: Text.AlignHCenter
                                    text: ws.modelData.id
                                    color: ws.toggled ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer3
                                }
                            }
                        }
                    }
                }
            }

            Item {
                Layout.fillHeight: true
            }
        }

        // Nothing shared yet: say how to start.
        ColumnLayout {
            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                margins: 14
            }
            visible: root.shares.length === 0
            spacing: 8

            MaterialSymbol {
                Layout.alignment: Qt.AlignHCenter
                text: "screen_share"
                iconSize: 36
                color: Appearance.colors.colSubtext
            }
            StyledText {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: Appearance.colors.colSubtext
                text: Translation.tr("In an app's screen-share dialog pick \"Share virtual screen\", then choose here which workspace it shows.")
            }
        }
    }
}
