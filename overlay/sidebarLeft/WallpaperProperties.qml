import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// The settings a Wallpaper Engine scene carries with it — colours, toggles,
// sliders and dropdowns the author exposed. They live in the scene's own
// project.json; mmsimpulse-wallpaper reads them, keeps every change in a file
// of its own so the workshop copy stays pristine, and restarts the renderer,
// which only reads properties at startup.
Rectangle {
    id: root

    property string wallpaperId: ""
    property string wallpaperTitle: ""
    property var properties: []
    signal closed

    color: Appearance.colors.colLayer1

    onWallpaperIdChanged: {
        root.properties = [];
        if (root.wallpaperId !== "") {
            propsProc.running = false;
            propsProc.running = true;
        }
    }

    function set(name, value) {
        Quickshell.execDetached(["mmsimpulse-wallpaper", "set", root.wallpaperId, name, String(value)]);
    }

    // "0.41 0.53 0.60" is how the scenes store a colour, and a swatch reads
    // better than three numbers.
    function toColor(triple) {
        const parts = String(triple).trim().split(/\s+/).map(parseFloat);
        if (parts.length < 3 || parts.some(isNaN))
            return Appearance.colors.colLayer2;
        return Qt.rgba(parts[0], parts[1], parts[2], 1);
    }

    function fromHex(text) {
        const hex = String(text).trim().replace(/^#/, "");
        if (!/^[0-9a-fA-F]{6}$/.test(hex))
            return "";
        const channel = i => (parseInt(hex.substr(i * 2, 2), 16) / 255).toFixed(5);
        return `${channel(0)} ${channel(1)} ${channel(2)}`;
    }

    Process {
        id: propsProc
        command: ["mmsimpulse-wallpaper", "props", root.wallpaperId]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.properties = JSON.parse(this.text);
                } catch (e) {
                    root.properties = [];
                }
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            RippleButton {
                implicitWidth: 32
                implicitHeight: 32
                buttonRadius: height / 2
                onClicked: root.closed()
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: "arrow_back"
                    iconSize: Appearance.font.pixelSize.larger
                    color: Appearance.colors.colOnLayer1
                }
            }

            StyledText {
                Layout.fillWidth: true
                text: root.wallpaperTitle
                elide: Text.ElideRight
                font.pixelSize: Appearance.font.pixelSize.normal
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: root.properties.length === 0
            text: Translation.tr("This wallpaper exposes no settings")
            color: Appearance.colors.colSubtext
        }

        StyledListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.properties.length > 0
            model: root.properties
            spacing: 6
            clip: true

            delegate: RowLayout {
                required property var modelData
                width: ListView.view.width
                spacing: 8

                StyledText {
                    Layout.fillWidth: true
                    text: modelData.text
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.font.pixelSize.smaller
                }

                StyledSwitch {
                    visible: modelData.type === "bool"
                    checked: String(modelData.value) === "true"
                    onToggled: root.set(modelData.name, checked)
                }

                // Committed on release rather than on every step: each change
                // restarts the renderer, and a dragged slider would restart it
                // a few dozen times on the way.
                RowLayout {
                    visible: modelData.type === "slider"
                    spacing: 4

                    StyledText {
                        text: slider.value.toFixed(2)
                        color: Appearance.colors.colSubtext
                        font.pixelSize: Appearance.font.pixelSize.smaller
                    }

                    StyledSlider {
                        id: slider
                        implicitWidth: 120
                        from: modelData.min
                        to: modelData.max
                        stepSize: modelData.step
                        value: parseFloat(modelData.value)
                        onPressedChanged: if (!pressed) root.set(modelData.name, value.toFixed(4))
                    }
                }

                StyledComboBox {
                    visible: modelData.type === "combo"
                    implicitWidth: 140
                    model: modelData.options.map(option => option.label)
                    currentIndex: Math.max(0, modelData.options.findIndex(option => String(option.value) === String(modelData.value)))
                    onActivated: index => root.set(modelData.name, modelData.options[index].value)
                }

                RowLayout {
                    visible: modelData.type === "color"
                    spacing: 4

                    Rectangle {
                        implicitWidth: 24
                        implicitHeight: 24
                        radius: Appearance.rounding.verysmall
                        color: root.toColor(modelData.value)
                        border.width: 1
                        border.color: Appearance.colors.colOutlineVariant
                    }

                    MaterialTextField {
                        implicitWidth: 110
                        text: modelData.value
                        placeholderText: "#rrggbb"
                        onEditingFinished: {
                            const triple = root.fromHex(text) || text;
                            root.set(modelData.name, triple);
                        }
                    }
                }

                MaterialTextField {
                    visible: modelData.type === "textinput"
                    implicitWidth: 150
                    text: modelData.value
                    onEditingFinished: root.set(modelData.name, text)
                }
            }
        }
    }
}
