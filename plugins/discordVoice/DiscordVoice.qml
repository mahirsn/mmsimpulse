import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets
import qs.plugins.discordVoice

// Bar widget: current voice state at a glance, controls on the widget itself.
// The popup is hover-driven, so it stays read-only and the actions live on the
// mouse buttons — the same shape Media.qml uses.
MouseArea {
    id: root

    property bool vertical: false

    readonly property bool connected: DiscordVoiceService.inVoice
    readonly property bool showName: !root.vertical && root.connected
        && (Config.options.bar.discordVoice?.showChannelName ?? true)
    readonly property bool hidden: !root.connected
        && (Config.options.bar.discordVoice?.hideWhenDisconnected ?? false)

    visible: !root.hidden
    implicitWidth: root.hidden ? 0 : (root.vertical ? 36 : contentRow.implicitWidth + 12)
    implicitHeight: root.vertical ? contentRow.implicitHeight + 8 : 32

    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton

    onPressed: event => {
        if (!DiscordVoiceService.authenticated) {
            DiscordVoiceService.authorize();
            return;
        }
        if (event.button === Qt.LeftButton) DiscordVoiceService.setMute(!DiscordVoiceService.muted);
        else if (event.button === Qt.MiddleButton) DiscordVoiceService.setDeaf(!DiscordVoiceService.deafened);
        else if (event.button === Qt.RightButton && root.connected) DiscordVoiceService.hangUp();
    }

    onWheel: event => {
        if (!DiscordVoiceService.authenticated) return;
        const step = event.angleDelta.y > 0 ? 5 : -5;
        DiscordVoiceService.setMicVolume(Math.max(0, Math.min(100, DiscordVoiceService.micVolume + step)));
    }

    RowLayout {
        id: contentRow
        anchors.centerIn: parent
        spacing: 4

        MaterialSymbol {
            // Material Symbols has no Discord brand glyph, so the widget shows
            // the state rather than the app.
            text: !DiscordVoiceService.authenticated ? "link_off"
                : DiscordVoiceService.deafened ? "headset_off"
                : DiscordVoiceService.muted ? "mic_off"
                : root.connected ? "headset_mic"
                : "voice_over_off"
            iconSize: Appearance.font.pixelSize.larger
            color: DiscordVoiceService.deafened || DiscordVoiceService.muted
                ? Appearance.colors.colOnLayer1
                : DiscordVoiceService.speakingCount > 0
                    ? Appearance.colors.colPrimary
                    : Appearance.colors.colOnLayer1
            opacity: root.connected ? 1 : 0.5
        }

        StyledText {
            visible: root.showName
            Layout.maximumWidth: 140
            elide: Text.ElideRight
            text: DiscordVoiceService.channelName
            color: Appearance.colors.colOnLayer1
            font.pixelSize: Appearance.font.pixelSize.smaller
            font.weight: Font.Medium
        }
    }

    DiscordVoicePanel { hoverTarget: root }
}
