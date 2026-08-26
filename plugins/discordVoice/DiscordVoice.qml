import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import "."

// Bar widget, following upstream's bar.luau: the glyph colours by state, the
// active speaker replaces it with their avatar, and a click opens the panel —
// or launches Discord when it is not running.
MouseArea {
    id: root

    property bool vertical: false
    readonly property var settings: Config.options.bar.discordVoice ?? ({})

    readonly property bool disconnected: !DiscordVoiceService.inVoice
    readonly property var speaker: DiscordVoiceService.activeSpeaker
    readonly property bool hidden: root.disconnected && (root.settings.hideWhenDisconnected ?? false)

    readonly property string glyphColor: {
        if (root.speaker) return Appearance.colors.colPrimary;
        if (!root.disconnected)
            return (DiscordVoiceService.muted || DiscordVoiceService.deafened)
                ? Appearance.m3colors.m3error : Appearance.colors.colPrimary;
        if (DiscordVoiceService.status === "error") return Appearance.m3colors.m3error;
        return Appearance.colors.colSubtext;
    }

    readonly property string statusLabel: {
        switch (DiscordVoiceService.status) {
        case "auth_required": return Translation.tr("Authorize");
        case "authorizing":
        case "authenticating": return Translation.tr("Authorizing…");
        case "discord_unavailable": return Translation.tr("Offline");
        case "error": return "!";
        }
        return "";
    }

    visible: !root.hidden
    implicitWidth: root.hidden ? 0 : (root.vertical ? 36 : contentRow.implicitWidth + 12)
    implicitHeight: root.vertical ? contentRow.implicitHeight + 8 : 32

    hoverEnabled: true
    onClicked: {
        if (DiscordVoiceService.status === "discord_unavailable") {
            DiscordVoiceService.openDiscord();
            return;
        }
        panel.open = !panel.open;
    }

    GridLayout {
        id: contentRow
        anchors.centerIn: parent
        columns: root.vertical ? 1 : -1
        rows: root.vertical ? -1 : 1
        columnSpacing: 6
        rowSpacing: 6

        // The speaker's avatar takes the glyph's place while they talk.

        MaterialSymbol {
            visible: !(root.speaker && (root.speaker.avatar_path ?? "") !== "")
            // Material Symbols carries no brand marks, so there is no Discord
            // glyph to match upstream's default; the state is shown instead.
            text: root.speaker ? "volume_up" : (root.settings.glyph || "headset_mic")
            iconSize: Appearance.font.pixelSize.larger
            color: root.glyphColor
        }

        StyledText {
            visible: root.disconnected && root.statusLabel.length > 0 && !root.vertical
            text: root.statusLabel
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.smaller
        }

        StyledText {
            visible: !root.disconnected && !root.vertical && (root.settings.showChannelName ?? true)
            Layout.maximumWidth: 150
            elide: Text.ElideRight
            text: DiscordVoiceService.channelName
            color: Appearance.colors.colOnLayer1
            font.pixelSize: Appearance.font.pixelSize.smaller
            font.weight: Font.Medium
        }

        StyledText {
            visible: !root.disconnected
            text: String(DiscordVoiceService.participants.length)
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.smaller
        }
    }

    DiscordVoicePanel {
        id: panel
        anchorItem: root
    }
}
