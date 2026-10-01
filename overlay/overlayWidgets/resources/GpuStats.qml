import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common

// GPU load, memory and temperature for the Resources widget, polled only while
// the widget exists. On a hybrid laptop the NVIDIA card sleeps when nothing
// uses it, and asking nvidia-smi would wake it and keep it awake: a sleeping
// card is reported as off and left alone.
QtObject {
    id: root

    readonly property int historyLength: Config.options?.resources?.historyLength ?? 60

    property bool hasAmd: false
    property real amdUsage: 0
    property real amdMemUsed: 0      // bytes
    property real amdMemTotal: 0
    property real amdTemp: 0
    property list<real> amdHistory: []

    property bool hasNvidia: false
    property bool nvidiaAwake: false
    property real nvidiaUsage: 0
    property real nvidiaMemUsed: 0   // bytes
    property real nvidiaMemTotal: 0
    property real nvidiaTemp: 0
    property list<real> nvidiaHistory: []

    // Fan speeds in rpm, from fans the laptop labels as the CPU's or the GPU's;
    // -1 where there is no such fan.
    property int cpuFan: -1
    property int gpuFan: -1

    function push(list, value) {
        const out = list.concat([value]);
        return out.length > root.historyLength ? out.slice(out.length - root.historyLength) : out;
    }

    function gb(bytes) {
        return (bytes / 1073741824).toFixed(1);
    }

    function memString(used, total) {
        return total > 0 ? `${gb(used)} / ${gb(total)} GB` : "";
    }

    property Process proc: Process {
        command: ["bash", "-c", `
            for c in /sys/class/drm/card*; do
                [[ $c =~ card[0-9]+$ && -r $c/device/vendor ]] || continue
                d=$c/device
                case $(cat $d/vendor) in
                0x1002)
                    t=$(cat $d/hwmon/hwmon*/temp1_input 2>/dev/null | head -1)
                    echo amd $(cat $d/gpu_busy_percent) $(cat $d/mem_info_vram_used) $(cat $d/mem_info_vram_total) \${t:-0} ;;
                0x10de)
                    if [[ $(cat $d/power/runtime_status) != active ]]; then echo nvidia off
                    else
                        nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu \\
                            --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d , | sed 's/^/nvidia /'
                    fi ;;
                esac
            done
            for l in /sys/class/hwmon/hwmon*/fan*_label; do
                case $(cat $l) in *cpu*|*gpu*) echo fan $(cat $l) $(cat \${l%_label}_input) ;; esac
            done 2>/dev/null`]
        stdout: StdioCollector {
            onStreamFinished: {
                for (const line of text.trim().split("\n")) {
                    const f = line.trim().split(/\s+/);
                    if (f[0] === "amd" && f.length >= 5) {
                        root.hasAmd = true;
                        root.amdUsage = Number(f[1]) / 100;
                        root.amdMemUsed = Number(f[2]);
                        root.amdMemTotal = Number(f[3]);
                        root.amdTemp = Number(f[4]) / 1000;
                        root.amdHistory = root.push(root.amdHistory, root.amdUsage);
                    } else if (f[0] === "nvidia") {
                        root.hasNvidia = true;
                        root.nvidiaAwake = f[1] !== "off" && f.length >= 5;
                        root.nvidiaUsage = root.nvidiaAwake ? Number(f[1]) / 100 : 0;
                        if (root.nvidiaAwake) {
                            root.nvidiaMemUsed = Number(f[2]) * 1048576;
                            root.nvidiaMemTotal = Number(f[3]) * 1048576;
                            root.nvidiaTemp = Number(f[4]);
                        }
                        root.nvidiaHistory = root.push(root.nvidiaHistory, root.nvidiaUsage);
                    } else if (f[0] === "fan" && f.length >= 3) {
                        if (f[1].includes("cpu")) root.cpuFan = Number(f[2]);
                        else root.gpuFan = Number(f[2]);
                    }
                }
            }
        }
    }

    property Timer timer: Timer {
        interval: Config.options?.resources?.updateInterval ?? 3000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.proc.running = false;
            root.proc.running = true;
        }
    }
}
