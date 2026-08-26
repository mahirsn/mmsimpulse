pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Talks to discord_bridge.py, which is the upstream Noctalia plugin's Python
// half taken verbatim. It knows nothing about Noctalia: `daemon` streams
// newline-delimited JSON snapshots on stdout, `command <name> [args]` performs
// an action. Same shape KwinBackend already consumes, so the port is the QML
// side only.
Singleton {
    id: root

    readonly property string bridge: Quickshell.shellPath("plugins/discordVoice/discord_bridge.py")

    property var snapshot: ({})

    readonly property string status: root.snapshot.status ?? "idle"
    readonly property string statusMessage: root.snapshot.status_message ?? ""
    readonly property bool authenticated: root.snapshot.authenticated ?? false
    readonly property var channel: root.snapshot.channel ?? null
    readonly property bool inVoice: !!root.channel
    readonly property string channelName: root.channel?.name ?? ""
    readonly property var participants: root.snapshot.participants ?? []
    readonly property var voice: root.snapshot.voice ?? ({})
    readonly property bool muted: root.voice.mute ?? false
    readonly property bool deafened: root.voice.deaf ?? false
    readonly property int micVolume: root.voice.input_volume ?? 100
    readonly property int speakingCount: root.participants.filter(p => p.speaking).length

    // Fire and forget: the daemon is the source of truth and pushes a fresh
    // snapshot after every change, so nothing here needs the reply.
    function command(args) {
        Quickshell.execDetached(["python3", root.bridge, "command"].concat(args));
    }

    function authorize() { root.command(["authorize"]) }
    function refresh() { root.command(["refresh"]) }
    function hangUp() { root.command(["hang-up"]) }
    function setMute(on) { root.command(["set-mute", on ? "true" : "false"]) }
    function setDeaf(on) { root.command(["set-deaf", on ? "true" : "false"]) }
    function setMicVolume(value) { root.command(["set-mic-volume", String(Math.round(value))]) }
    function setUserVolume(userId, value) {
        root.command(["set-user-volume", String(userId), String(Math.round(value))]);
    }
    function joinChannel(id) { root.command(["join-channel", String(id)]) }
    function favoriteChannel(id) { root.command(["favorite-channel", String(id)]) }
    function unfavoriteChannel(id) { root.command(["unfavorite-channel", String(id)]) }

    Process {
        id: daemon
        running: true
        command: ["python3", root.bridge, "daemon"]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                if (line.trim().length === 0) return;
                try {
                    const event = JSON.parse(line);
                    // A heartbeat every 5s only says the bridge is alive.
                    if (event.type === "snapshot") root.snapshot = event;
                } catch (e) {
                    console.log("[DiscordVoice] parse error: " + e);
                }
            }
        }
        stderr: SplitParser {
            splitMarker: "\n"
            onRead: line => console.log("[DiscordVoice] " + line)
        }
        onExited: restartTimer.restart()
    }

    Timer { id: restartTimer; interval: 2000; onTriggered: daemon.running = true }

    // The daemon holds Discord's RPC socket; leaving it behind would block the
    // next shell start from connecting.
    Component.onDestruction: root.command(["shutdown"])
}
