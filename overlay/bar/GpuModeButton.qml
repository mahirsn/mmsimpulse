import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Which GPU drives the laptop's own screen, on ASUS laptops with a GPU MUX:
// the AMD iGPU (supergfxd's Hybrid) or the NVIDIA dGPU (AsusMuxDgpu), where
// games skip the copy from one GPU to the other. The MUX only changes on
// boot, so the button asks first and then restarts.
Item {
    id: root
    property bool isMaterial: false

    // supergfxd's GfxMode numbers.
    readonly property int hybrid: 0
    readonly property int muxDgpu: 5
    property int mode: -1
    readonly property bool dgpu: mode === muxDgpu
    readonly property string targetIcon: dgpu ? "amd-symbolic.svg" : "nvidia-symbolic.svg"
    property bool asking: false
    // A Material Symbol leaves padding around its glyph and the logos have
    // none, and the symbols next to it are outlines where the logos are solid,
    // which reads bigger at the same size. Sized by eye against them: the
    // square AMD logo a little under the 15px symbols, the wide NVIDIA one
    // about the keyboard's height -- in the same box it would come out thin.
    readonly property int logoSize: Appearance.font.pixelSize.large - (dgpu ? 5 : 6)

    visible: mode >= 0 && Config.options.bar.utilButtons.showGpuModeToggle
    implicitWidth: button.item?.implicitWidth ?? 0
    implicitHeight: button.item?.implicitHeight ?? 0

    readonly property string gfx: "busctl --system call org.supergfxctl.Daemon /org/supergfxctl/Gfx org.supergfxctl.Daemon"

    // Only on an AMD CPU with an NVIDIA dGPU behind a MUX supergfxd can flip --
    // the two logos are the whole button, and any other pair would be a lie.
    // In dGPU mode supergfxd lists AsusMuxDgpu alone, so that check still
    // holds; its Vendor does not (it answers "AMD" there), so the NVIDIA card
    // is looked for on the PCI bus instead: vendor 10de, display class.
    Process {
        running: true
        command: ["bash", "-c", `
            grep -qm1 AuthenticAMD /proc/cpuinfo || exit 1
            grep -lx 0x10de /sys/bus/pci/devices/*/vendor 2>/dev/null | sed 's/vendor$/class/' \
                | xargs -r grep -qx '0x03.*' || exit 1
            set -- $(${root.gfx} Supported); shift 2
            case " $* " in *" ${root.muxDgpu} "*) ;; *) exit 1 ;; esac
            ${root.gfx} Mode | cut -d' ' -f2`]
        stdout: StdioCollector {
            onStreamFinished: {
                const mode = parseInt(text);
                root.mode = isNaN(mode) ? -1 : mode;
            }
        }
    }

    // SetMode returns before supergfxd has done the work, and a reboot in
    // between would come back on the old GPU. It clears the pending mode when
    // done and records the new mode only on success, so wait for the first and
    // check the second.
    Process {
        id: switcher
        property int target
        command: ["bash", "-c", `
            ${root.gfx} SetMode u "$1" >/dev/null || exit 1
            for _ in $(seq 100); do
                [ "$(${root.gfx} PendingMode)" = "u 6" ] && break
                sleep 0.1
            done
            [ "$(${root.gfx} Config | cut -d' ' -f2)" = "$1" ] \
                || { echo "supergfxd did not finish the switch" >&2; exit 1; }`,
            "gpu-mode", `${target}`]
        stderr: StdioCollector { id: switchError }
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                Session.reboot();
                return;
            }
            root.asking = false;
            Quickshell.execDetached(["notify-send", "-a", "Shell", "-i", "dialog-error",
                Translation.tr("Couldn't switch the GPU"), switchError.text.trim()]);
        }
    }

    Loader {
        id: button
        sourceComponent: root.isMaterial ? m3Button : legacyButton
    }

    Component {
        id: m3Button
        UtilButton {
            id: m3
            iconText: ""
            onClicked: root.asking = true
            CustomIcon {
                anchors.centerIn: parent
                width: root.logoSize
                height: root.logoSize
                source: root.dgpu ? "nvidia-symbolic.svg" : "amd-symbolic.svg"
                colorize: true
                color: m3.hovered ? Appearance.colors.colOnPrimary : Appearance.colors.colPrimary
            }
        }
    }

    Component {
        id: legacyButton
        CircleUtilButton {
            onClicked: root.asking = true
            Item {
                CustomIcon {
                    anchors.centerIn: parent
                    width: root.logoSize
                    height: root.logoSize
                    source: root.dgpu ? "nvidia-symbolic.svg" : "amd-symbolic.svg"
                    colorize: true
                    color: Appearance.colors.colOnLayer2
                }
            }
        }
    }

    Loader {
        active: root.asking
        sourceComponent: PanelWindow {
            screen: root.QsWindow?.window?.screen ?? null
            anchors {
                top: true
                left: true
                right: true
                bottom: true
            }
            color: "transparent"
            WlrLayershell.namespace: "quickshell:gpuMode"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            exclusionMode: ExclusionMode.Ignore

            WindowDialog {
                id: dialog
                anchors.fill: parent
                backgroundWidth: 400
                focus: true
                Component.onCompleted: show = true
                onDismiss: {
                    if (!switcher.running) show = false;
                }
                // Let the closing animation finish before the window goes.
                onVisibleChanged: {
                    if (!visible) root.asking = false;
                }

                CustomIcon {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: 26
                    Layout.preferredHeight: 26
                    source: root.targetIcon
                    colorize: true
                    color: Appearance.colors.colSecondary
                }

                WindowDialogTitle {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: root.dgpu ? Translation.tr("Switch the display to AMD?")
                                    : Translation.tr("Switch the display to NVIDIA?")
                }

                WindowDialogParagraph {
                    Layout.fillWidth: true
                    text: (root.dgpu
                        ? Translation.tr("Switches from discrete GPU only back to Hybrid mode.")
                        : Translation.tr("Switches from Hybrid mode to discrete GPU only."))
                        + "\n\n" + Translation.tr("The computer restarts to switch. Unsaved work in open apps will be lost.")
                }

                WindowDialogButtonRow {
                    Layout.bottomMargin: 10
                    Item {
                        Layout.fillWidth: true
                    }
                    DialogButton {
                        buttonText: Translation.tr("Cancel")
                        enabled: !switcher.running
                        onClicked: dialog.show = false
                    }
                    DialogButton {
                        buttonText: switcher.running ? Translation.tr("Switching...") : Translation.tr("Restart")
                        enabled: !switcher.running
                        onClicked: {
                            switcher.target = root.dgpu ? root.hybrid : root.muxDgpu;
                            switcher.running = true;
                        }
                    }
                }
            }
        }
    }
}
