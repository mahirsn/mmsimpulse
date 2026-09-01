import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Wallpaper picker for the left sidebar. Every source it offers is one the
// session can actually play: Wallpaper Engine's workshop through
// linux-wallpaperengine, video files through mpvpaper, and plain images
// through the skin's own switchwall.sh. mmsimpulse-wallpaper knows which is
// which, so this page only has to draw what it reports and hand back a choice.
Item {
    id: root

    readonly property var sources: ["engine", "local", "video"]
    property int sourceIndex: 0
    property var entries: []
    property string editingId: ""
    property string editingTitle: ""
    readonly property var shown: root.entries.filter(entry => entry.source === root.sources[root.sourceIndex])

    function reload() {
        indexProc.running = false;
        indexProc.running = true;
    }

    function apply(arg) {
        Quickshell.execDetached(["mmsimpulse-wallpaper", arg]);
    }

    Process {
        id: indexProc
        command: ["mmsimpulse-wallpaper", "index"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.entries = JSON.parse(this.text);
                } catch (e) {
                    root.entries = [];
                }
            }
        }
    }

    Component.onCompleted: root.reload()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            SecondaryTabBar {
                id: tabBar
                Layout.fillWidth: true
                currentIndex: root.sourceIndex
                onCurrentIndexChanged: root.sourceIndex = tabBar.currentIndex

                SecondaryTabButton {
                    buttonIcon: "wallpaper"
                    buttonText: Translation.tr("Engine")
                }
                SecondaryTabButton {
                    buttonIcon: "image"
                    buttonText: Translation.tr("Images")
                }
                SecondaryTabButton {
                    buttonIcon: "movie"
                    buttonText: Translation.tr("Videos")
                }
            }

            // Stopping is its own action rather than a fourth tab: it puts the
            // still image back, which is not a wallpaper you pick from a grid.
            RippleButton {
                implicitWidth: 36
                implicitHeight: 36
                buttonRadius: height / 2
                onClicked: root.apply("off")
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: "stop_circle"
                    iconSize: Appearance.font.pixelSize.larger
                    color: Appearance.colors.colOnLayer1
                }
            }
        }

        GridView {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.shown
            cellWidth: Math.floor(grid.width / 2)
            cellHeight: Math.round(cellWidth * 9 / 16)
            // 110 workshop previews would otherwise all decode at full size.
            readonly property int previewWidth: 320

            StyledText {
                anchors.centerIn: parent
                visible: grid.count === 0
                color: Appearance.colors.colSubtext
                text: root.sourceIndex === 0
                    ? Translation.tr("No Wallpaper Engine wallpapers found")
                    : Translation.tr("Nothing here")
            }

            delegate: Item {
                required property var modelData
                width: grid.cellWidth
                height: grid.cellHeight

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 4
                    radius: Appearance.rounding.small
                    color: Appearance.colors.colLayer2
                    clip: true

                    Image {
                        anchors.fill: parent
                        visible: parent.width > 0 && source !== ""
                        source: modelData.preview ? `file://${modelData.preview}` : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: false
                        sourceSize.width: grid.previewWidth
                    }

                    MouseArea {
                        id: pick
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.apply(modelData.arg)
                    }

                    Rectangle {
                        anchors.fill: parent
                        visible: pick.containsMouse
                        color: Appearance.colors.colLayer2Hover
                        opacity: 0.4
                    }

                    // The title is unreadable straight on a bright preview, and
                    // a scrim is cheaper than measuring the image behind it.
                    Rectangle {
                        anchors {
                            left: parent.left
                            right: parent.right
                            bottom: parent.bottom
                        }
                        height: label.implicitHeight + 8
                        color: Qt.rgba(0, 0, 0, 0.55)

                        StyledText {
                            id: label
                            anchors {
                                fill: parent
                                margins: 4
                            }
                            text: modelData.title
                            color: "white"
                            elide: Text.ElideRight
                            font.pixelSize: Appearance.font.pixelSize.smaller
                        }
                    }

                    // A scene carries settings of its own; a video is a video.
                    RippleButton {
                        visible: modelData.type === "scene"
                        anchors {
                            top: parent.top
                            left: parent.left
                            margins: 4
                        }
                        implicitWidth: 26
                        implicitHeight: 26
                        buttonRadius: height / 2
                        colBackground: Appearance.colors.colLayer1
                        onClicked: {
                            root.editingTitle = modelData.title;
                            root.editingId = modelData.arg;
                        }
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            text: "tune"
                            iconSize: Appearance.font.pixelSize.normal
                            color: Appearance.colors.colOnLayer1
                        }
                    }

                    // Only the workshop mixes types, and which one it is decides
                    // whether the scene renderer or mpvpaper has to come up.
                    Rectangle {
                        visible: modelData.source === "engine"
                        anchors {
                            top: parent.top
                            right: parent.right
                            margins: 4
                        }
                        width: badge.implicitWidth + 8
                        height: badge.implicitHeight + 4
                        radius: Appearance.rounding.verysmall
                        color: Appearance.colors.colPrimaryContainer

                        StyledText {
                            id: badge
                            anchors.centerIn: parent
                            text: modelData.type
                            color: Appearance.colors.colOnPrimaryContainer
                            font.pixelSize: Appearance.font.pixelSize.smallest
                        }
                    }
                }
            }
        }
    }

    WallpaperProperties {
        anchors.fill: parent
        visible: root.editingId !== ""
        wallpaperId: root.editingId
        wallpaperTitle: root.editingTitle
        onClosed: root.editingId = ""
    }
}
