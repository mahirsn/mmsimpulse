import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets
import qs.plugins.discordVoice

// Read-only status for the bar widget's hover popup. Deliberately has no
// controls: StyledPopup closes as soon as the pointer leaves the widget, so
// anything clickable here would be unreachable. The actions are on the
// widget's mouse buttons instead.
StyledPopup {
    id: root

    ColumnLayout {
        spacing: 6

        StyledText {
            text: !DiscordVoiceService.authenticated
                ? Translation.tr("Discord not authorised")
                : DiscordVoiceService.inVoice
                    ? DiscordVoiceService.channelName
                    : Translation.tr("Not in a voice channel")
            color: Appearance.colors.colOnLayer1
            font.pixelSize: Appearance.font.pixelSize.normal
            font.weight: Font.Medium
        }

        StyledText {
            visible: text.length > 0
            Layout.maximumWidth: 260
            wrapMode: Text.Wrap
            text: !DiscordVoiceService.authenticated
                ? Translation.tr("Click the widget to authorise")
                : (DiscordVoiceService.statusMessage || "")
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.smaller
        }

        StyledText {
            visible: DiscordVoiceService.authenticated
            text: Translation.tr("Mic %1%").arg(DiscordVoiceService.micVolume)
                + (DiscordVoiceService.muted ? " · " + Translation.tr("muted") : "")
                + (DiscordVoiceService.deafened ? " · " + Translation.tr("deafened") : "")
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.smaller
        }

        Repeater {
            model: DiscordVoiceService.participants
            RowLayout {
                id: participantRow
                required property var modelData
                spacing: 6

                MaterialSymbol {
                    text: participantRow.modelData.deaf || participantRow.modelData.self_deaf ? "headset_off"
                        : participantRow.modelData.mute || participantRow.modelData.self_mute ? "mic_off"
                        : participantRow.modelData.speaking ? "graphic_eq"
                        : "person"
                    iconSize: Appearance.font.pixelSize.smaller
                    color: participantRow.modelData.speaking
                        ? Appearance.colors.colPrimary
                        : Appearance.colors.colSubtext
                }

                StyledText {
                    Layout.maximumWidth: 200
                    elide: Text.ElideRight
                    text: participantRow.modelData.nick ?? participantRow.modelData.username ?? ""
                    color: Appearance.colors.colOnLayer1
                    font.pixelSize: Appearance.font.pixelSize.smaller
                }
            }
        }

        StyledText {
            visible: DiscordVoiceService.inVoice
            text: Translation.tr("Left click mute · middle deafen · right hang up · scroll mic")
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.smallest
        }
    }
}
