pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common

// Talks to discord_bridge.py, which is the upstream Noctalia plugin's Python
// half taken verbatim. It knows nothing about Noctalia: `daemon` streams
// newline-delimited JSON snapshots on stdout, `command <name> [args]` performs
// an action and answers with a JSON result. Same shape KwinBackend already
// consumes, so the port is the QML side only.
Singleton {
    id: root

    readonly property string bridge: Quickshell.shellPath("plugins/discordVoice/discord_bridge.py")
    property string discordBinary: Config.options.bar.discordVoice?.discordBinary ?? "/usr/bin/discord"

    property var snapshot: ({})

    readonly property string status: root.snapshot.status ?? "starting"
    readonly property string statusMessage: root.snapshot.status_message ?? ""
    readonly property bool authenticated: root.snapshot.authenticated ?? false
    readonly property var user: root.snapshot.user ?? ({})
    readonly property var channel: root.snapshot.channel ?? null
    readonly property bool inVoice: !!root.channel
    readonly property string channelName: root.channel?.name ?? ""
    readonly property var participants: root.snapshot.participants ?? []
    readonly property var recentChannels: root.snapshot.recent_channels ?? []
    readonly property var favoriteChannels: root.snapshot.favorite_channels ?? []
    readonly property var voice: root.snapshot.voice ?? ({})
    readonly property var connection: root.snapshot.connection ?? ({})
    readonly property int connectedSince: root.snapshot.connected_since ?? 0
    readonly property bool muted: root.voice.mute ?? false
    readonly property bool deafened: root.voice.deaf ?? false
    readonly property int micVolume: root.voice.input_volume ?? 100
    readonly property var activeSpeaker: root.participants.find(p => p.speaking) ?? null

    // Upstream gates its buttons on a command being in flight and shows the
    // error text from the bridge's JSON reply, so keep both.
    property bool actionPending: false
    property string actionError: ""

    function isFavorite(channelId) {
        return root.favoriteChannels.some(c => c.id === channelId);
    }

    function command(args) {
        if (root.actionPending) return;
        root.actionPending = true;
        root.actionError = "";
        commandProc.command = ["python3", root.bridge, "command"].concat(args);
        commandProc.running = true;
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
    function toggleFavorite(id) {
        root.command([root.isFavorite(id) ? "unfavorite-channel" : "favorite-channel", String(id)]);
    }

    // Upstream opens the active channel by URI when there is one, and just
    // starts the app otherwise.
    function openDiscord() {
        const c = root.channel;
        if (c && c.guild_id && c.id) {
            Quickshell.execDetached([root.discordBinary, "--url", "--",
                `discord://discord.com/channels/${c.guild_id}/${c.id}`]);
        } else {
            Quickshell.execDetached([root.discordBinary]);
        }
    }

    Process {
        id: commandProc
        stdout: StdioCollector {
            onStreamFinished: {
                root.actionPending = false;
                try {
                    const reply = JSON.parse(text);
                    if (reply.ok === false) root.actionError = reply.error ?? "";
                } catch (e) {
                    // A command that prints nothing is a success in this bridge.
                }
            }
        }
        onExited: root.actionPending = false
    }

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
    Component.onDestruction: Quickshell.execDetached(["python3", root.bridge, "command", "shutdown"])
}
