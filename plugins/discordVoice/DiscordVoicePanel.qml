pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.services
import "."

// Port of upstream's panel.luau, kept close to it: same sections, same states,
// same wording. Tabler glyph names are mapped to Material Symbols, which is
// what this shell ships — the one thing that cannot be matched is the Discord
// brand mark, since Material Symbols carries no brand icons.
Scope {
    id: root

    property Item anchorItem
    property bool open: false

    readonly property var svc: DiscordVoiceService

    function connectionAppearance() {
        const state = root.svc.connection.state ?? "";
        const ping = root.svc.connection.average_ping ?? 0;
        if (state === "VOICE_CONNECTED") {
            if (ping <= 0)
                return { icon: "wifi", color: Appearance.colors.colPrimary, label: Translation.tr("Connected") };
            const color = ping <= 60 ? Appearance.colors.colPrimary
                : ping <= 120 ? Appearance.colors.colTertiary
                : Appearance.m3colors.m3error;
            return { icon: "wifi", color: color, label: `${Math.floor(ping)} ms` };
        }
        if (state === "NO_ROUTE")
            return { icon: "wifi_off", color: Appearance.m3colors.m3error, label: Translation.tr("No route") };
        if (state === "DISCONNECTED" || state === "VOICE_DISCONNECTED")
            return { icon: "wifi_off", color: Appearance.colors.colSubtext, label: Translation.tr("Disconnected") };
        return { icon: "progress_activity", color: Appearance.colors.colTertiary, label: Translation.tr("Connecting") };
    }

    function durationText() {
        const since = root.svc.connectedSince;
        if (!since) return "--:--";
        const total = Math.max(0, ticker.now - since);
        const h = Math.floor(total / 3600);
        const m = Math.floor((total % 3600) / 60);
        const s = total % 60;
        const pad = v => String(v).padStart(2, "0");
        return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
    }

    // Upstream asks the panel for per-second ticks only while it is open.
    Timer {
        id: ticker
        property int now: Math.floor(Date.now() / 1000)
        running: root.open && root.svc.inVoice
        repeat: true
        interval: 1000
        onTriggered: now = Math.floor(Date.now() / 1000)
    }

    LazyLoader {
        active: root.open && root.anchorItem

        PopupWindow {
            id: popup
            visible: true
            color: "transparent"
            implicitWidth: 600
            implicitHeight: 640

            anchor {
                window: root.anchorItem.QsWindow.window
                item: root.anchorItem
                edges: Edges.Bottom
                gravity: Edges.Bottom
            }

            Rectangle {
                anchors.fill: parent
                anchors.margins: 8
                radius: Appearance.rounding.large
                color: Appearance.colors.colLayer0
                border.color: ColorUtils.transparentize(Appearance.m3colors.m3outline, 0.7)
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 12

                    // ---- header -------------------------------------------
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        MaterialSymbol {
                            text: "forum"
                            iconSize: 20
                            color: Appearance.colors.colPrimary
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: Translation.tr("Discord Voice")
                            font.pixelSize: Appearance.font.pixelSize.large
                            font.weight: Font.Bold
                            color: Appearance.colors.colOnLayer1
                        }
                        GhostButton {
                            icon: "close"
                            onClicked: root.open = false
                        }
                    }

                    StyledText {
                        Layout.fillWidth: true
                        visible: root.svc.actionError.length > 0
                        text: root.svc.actionError
                        wrapMode: Text.Wrap
                        maximumLineCount: 3
                        color: Appearance.m3colors.m3error
                        font.pixelSize: Appearance.font.pixelSize.smallest
                    }

                    // ---- body ---------------------------------------------
                    Loader {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        sourceComponent: root.svc.authenticated ? voiceBody : disconnectedBody
                    }
                }
            }
        }
    }

    // ---- not authenticated / no Discord ---------------------------------
    Component {
        id: disconnectedBody
        ColumnLayout {
            spacing: 10

            Item { Layout.fillHeight: true }

            MaterialSymbol {
                Layout.alignment: Qt.AlignHCenter
                text: {
                    switch (root.svc.status) {
                    case "auth_required": return "forum";
                    case "discord_unavailable": return "forum";
                    case "error": return "error";
                    }
                    return "progress_activity";
                }
                iconSize: 46
                color: root.svc.status === "error"
                    ? Appearance.m3colors.m3error
                    : root.svc.status === "discord_unavailable"
                        ? Appearance.colors.colSubtext
                        : Appearance.colors.colPrimary
            }

            StyledText {
                Layout.alignment: Qt.AlignHCenter
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: Appearance.font.pixelSize.larger
                font.weight: Font.Bold
                color: root.svc.status === "error" ? Appearance.m3colors.m3error : Appearance.colors.colOnLayer1
                text: {
                    switch (root.svc.status) {
                    case "auth_required": return Translation.tr("Authorize Discord Voice");
                    case "authorizing":
                    case "authenticating": return Translation.tr("Waiting for Discord");
                    case "discord_unavailable": return Translation.tr("Discord is unavailable");
                    case "error": return Translation.tr("Discord voice error");
                    }
                    return Translation.tr("Starting");
                }
            }

            StyledText {
                Layout.alignment: Qt.AlignHCenter
                Layout.maximumWidth: 420
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                maximumLineCount: 4
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.small
                text: {
                    if (root.svc.statusMessage.length > 0) return root.svc.statusMessage;
                    switch (root.svc.status) {
                    case "auth_required":
                        return Translation.tr("Discord will ask you to grant local voice read and control access through its StreamKit integration.");
                    case "authorizing":
                    case "authenticating":
                        return Translation.tr("Complete the authorization prompt in the Discord desktop app.");
                    case "discord_unavailable":
                        return Translation.tr("Start the Discord desktop app. The bridge will reconnect automatically.");
                    }
                    return "";
                }
            }

            RippleButton {
                Layout.alignment: Qt.AlignHCenter
                visible: root.svc.status === "auth_required" || root.svc.status === "discord_unavailable"
                enabled: !root.svc.actionPending
                buttonText: root.svc.status === "auth_required"
                    ? Translation.tr("Authorize Discord")
                    : Translation.tr("Open in Discord")
                onClicked: root.svc.status === "auth_required" ? root.svc.authorize() : root.svc.openDiscord()
            }

            Item { Layout.fillHeight: true }
        }
    }

    // ---- authenticated ---------------------------------------------------
    Component {
        id: voiceBody
        ColumnLayout {
            spacing: 12

            // -- not in a channel: the saved channel list ------------------
            ColumnLayout {
                visible: !root.svc.inVoice
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 10

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 46
                    radius: Appearance.rounding.normal
                    color: ColorUtils.transparentize(Appearance.colors.colLayer1, 0.76)
                    border.color: ColorUtils.transparentize(Appearance.m3colors.m3outline, 0.66)
                    border.width: 1
                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 8
                        MaterialSymbol { text: "headphones"; iconSize: 20; color: Appearance.colors.colSubtext }
                        StyledText {
                            text: Translation.tr("Not in an active channel")
                            font.pixelSize: Appearance.font.pixelSize.normal
                            font.weight: Font.Bold
                            color: Appearance.colors.colOnLayer1
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    MaterialSymbol { text: "history"; iconSize: 18; color: Appearance.colors.colPrimary }
                    StyledText {
                        Layout.fillWidth: true
                        text: Translation.tr("Recent channels")
                        font.pixelSize: Appearance.font.pixelSize.normal
                        font.weight: Font.Bold
                        color: Appearance.colors.colOnLayer1
                    }
                    GhostButton { icon: "open_in_new"; onClicked: root.svc.openDiscord() }
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: channelRepeater.count === 0
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: Translation.tr("Your five most recently joined channels will appear here.")
                    color: Appearance.colors.colSubtext
                }

                StyledFlickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: channelColumn.implicitHeight
                    clip: true
                    ColumnLayout {
                        id: channelColumn
                        width: parent.width
                        spacing: 8
                        Repeater {
                            id: channelRepeater
                            // Favourites first, then recents that are not already favourites.
                            model: {
                                const favs = root.svc.favoriteChannels;
                                const ids = favs.map(c => c.id);
                                return favs.concat(root.svc.recentChannels.filter(c => !ids.includes(c.id)));
                            }
                            ChannelRow { required property var modelData; channel: modelData }
                        }
                    }
                }
            }

            // -- in a channel ----------------------------------------------
            ColumnLayout {
                visible: root.svc.inVoice
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 12

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: headerColumn.implicitHeight + 26
                    radius: Appearance.rounding.large
                    color: ColorUtils.transparentize(Appearance.colors.colLayer1, 0.76)
                    border.color: ColorUtils.transparentize(Appearance.m3colors.m3outline, 0.62)
                    border.width: 1

                    ColumnLayout {
                        id: headerColumn
                        anchors.fill: parent
                        anchors.margins: 13
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            MaterialSymbol { text: "dns"; iconSize: 17; color: Appearance.colors.colSubtext }
                            StyledText {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: root.svc.channel?.guild_name || Translation.tr("Unknown server")
                                font.weight: Font.Bold
                                color: Appearance.colors.colOnLayer1
                            }
                            GhostButton {
                                icon: root.svc.isFavorite(root.svc.channel?.id ?? "") ? "star" : "star_border"
                                highlighted: root.svc.isFavorite(root.svc.channel?.id ?? "")
                                enabled: !root.svc.actionPending
                                onClicked: root.svc.toggleFavorite(root.svc.channel?.id ?? "")
                            }
                            GhostButton { icon: "open_in_new"; onClicked: root.svc.openDiscord() }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            MaterialSymbol { text: "volume_up"; iconSize: 18; color: Appearance.colors.colPrimary }
                            StyledText {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: root.svc.channelName
                                font.pixelSize: Appearance.font.pixelSize.normal
                                font.weight: Font.Bold
                                color: Appearance.colors.colPrimary
                            }
                        }

                        RowLayout {
                            spacing: 14
                            RowLayout {
                                spacing: 5
                                MaterialSymbol { text: "schedule"; iconSize: 14; color: Appearance.colors.colSubtext }
                                StyledText {
                                    text: root.durationText()
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: Appearance.colors.colSubtext
                                }
                            }
                            Rectangle {
                                readonly property var appearance: root.connectionAppearance()
                                implicitWidth: connRow.implicitWidth + 16
                                implicitHeight: connRow.implicitHeight + 6
                                radius: Appearance.rounding.small
                                color: ColorUtils.transparentize(appearance.color, 0.87)
                                border.color: ColorUtils.transparentize(appearance.color, 0.7)
                                border.width: 1
                                RowLayout {
                                    id: connRow
                                    anchors.centerIn: parent
                                    spacing: 5
                                    MaterialSymbol {
                                        text: parent.parent.appearance.icon
                                        iconSize: 14
                                        color: parent.parent.appearance.color
                                    }
                                    StyledText {
                                        text: parent.parent.appearance.label
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: parent.parent.appearance.color
                                    }
                                }
                            }
                            RowLayout {
                                spacing: 5
                                MaterialSymbol { text: "group"; iconSize: 14; color: Appearance.colors.colSubtext }
                                StyledText {
                                    text: String(root.svc.participants.length)
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: Appearance.colors.colSubtext
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: controlsRow.implicitHeight + 16
                    radius: Appearance.rounding.normal
                    color: ColorUtils.transparentize(Appearance.colors.colLayer1, 0.82)
                    border.color: ColorUtils.transparentize(Appearance.m3colors.m3outline, 0.7)
                    border.width: 1
                    RowLayout {
                        id: controlsRow
                        anchors.fill: parent
                        anchors.margins: 8
                        spacing: 9
                        RippleButton {
                            Layout.fillWidth: true
                            enabled: !root.svc.actionPending
                            toggled: root.svc.muted
                            buttonText: root.svc.muted ? Translation.tr("Unmute") : Translation.tr("Mute")
                            onClicked: root.svc.setMute(!root.svc.muted)
                        }
                        RippleButton {
                            Layout.fillWidth: true
                            enabled: !root.svc.actionPending
                            toggled: root.svc.deafened
                            buttonText: root.svc.deafened ? Translation.tr("Undeafen") : Translation.tr("Deafen")
                            onClicked: root.svc.setDeaf(!root.svc.deafened)
                        }
                        RippleButton {
                            Layout.fillWidth: true
                            enabled: !root.svc.actionPending
                            buttonText: Translation.tr("Hang up")
                            onClicked: root.svc.hangUp()
                        }
                    }
                }

                StyledText {
                    text: Translation.tr("Participants (%1)").arg(root.svc.participants.length)
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    font.weight: Font.Bold
                    color: Appearance.colors.colSubtext
                }

                StyledFlickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: participantColumn.implicitHeight
                    clip: true
                    ColumnLayout {
                        id: participantColumn
                        width: parent.width
                        spacing: 8
                        Repeater {
                            model: root.svc.participants
                            ParticipantRow { required property var modelData; participant: modelData }
                        }
                    }
                }
            }
        }
    }

    // ---- reusable rows ---------------------------------------------------
    component GhostButton: MouseArea {
        property string icon: ""
        property bool highlighted: false
        implicitWidth: 28
        implicitHeight: 28
        hoverEnabled: true
        MaterialSymbol {
            anchors.centerIn: parent
            text: parent.icon
            iconSize: 18
            color: parent.highlighted ? Appearance.colors.colPrimary
                : parent.containsMouse ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
        }
    }

    component ChannelRow: Rectangle {
        id: channelRow
        property var channel
        readonly property bool favorite: DiscordVoiceService.isFavorite(channelRow.channel?.id ?? "")
        Layout.fillWidth: true
        implicitHeight: 44
        radius: Appearance.rounding.normal
        color: ColorUtils.transparentize(Appearance.colors.colLayer1, 0.74)
        border.color: ColorUtils.transparentize(Appearance.m3colors.m3outline, 0.66)
        border.width: 1

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 7

            GhostButton {
                icon: channelRow.favorite ? "star" : "star_border"
                highlighted: channelRow.favorite
                enabled: !DiscordVoiceService.actionPending
                onClicked: DiscordVoiceService.toggleFavorite(channelRow.channel.id)
            }
            StyledText {
                Layout.preferredWidth: 120
                elide: Text.ElideRight
                text: channelRow.channel?.guild_name || Translation.tr("Unknown server")
                font.weight: Font.Bold
                color: Appearance.colors.colPrimary
            }
            StyledText { text: "/"; color: Appearance.colors.colSubtext }
            StyledText {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: channelRow.channel?.name ?? ""
                color: Appearance.colors.colSubtext
            }
            RowLayout {
                spacing: 4
                visible: (channelRow.channel?.participant_count ?? 0) > 0
                MaterialSymbol { text: "group"; iconSize: 14; color: Appearance.colors.colPrimary }
                StyledText {
                    text: String(channelRow.channel?.participant_count ?? 0)
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    font.weight: Font.Bold
                    color: Appearance.colors.colPrimary
                }
            }
            RippleButton {
                enabled: !DiscordVoiceService.actionPending
                buttonText: Translation.tr("Join")
                onClicked: DiscordVoiceService.joinChannel(channelRow.channel.id)
            }
        }
    }

    component ParticipantRow: Rectangle {
        id: participantRow
        property var participant
        readonly property bool speaking: participantRow.participant?.speaking ?? false
        readonly property bool isSelf: (participantRow.participant?.id ?? "") === (DiscordVoiceService.user.id ?? "")
        readonly property bool muted: (participantRow.participant?.mute ?? false)
            || (participantRow.participant?.self_mute ?? false)
            || (participantRow.participant?.local_mute ?? false)
        readonly property bool deafened: (participantRow.participant?.deaf ?? false)
            || (participantRow.participant?.self_deaf ?? false)

        Layout.fillWidth: true
        implicitHeight: rowLayout.implicitHeight + 12
        radius: Appearance.rounding.normal
        color: participantRow.speaking
            ? ColorUtils.transparentize(Appearance.colors.colPrimary, 0.9)
            : ColorUtils.transparentize(Appearance.colors.colLayer1, 0.76)
        border.color: participantRow.speaking
            ? ColorUtils.transparentize(Appearance.colors.colPrimary, 0.45)
            : ColorUtils.transparentize(Appearance.m3colors.m3outline, 0.68)
        border.width: 1

        RowLayout {
            id: rowLayout
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            anchors.topMargin: 6
            anchors.bottomMargin: 6
            spacing: 10

            Image {
                visible: (participantRow.participant?.avatar_path ?? "") !== ""
                source: visible ? `file://${participantRow.participant.avatar_path}` : ""
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                sourceSize: Qt.size(36, 36)
                fillMode: Image.PreserveAspectCrop
            }
            MaterialSymbol {
                visible: (participantRow.participant?.avatar_path ?? "") === ""
                text: "account_circle"
                iconSize: 36
                color: participantRow.speaking ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: (participantRow.participant?.nick ?? "")
                            + (participantRow.isSelf ? " " + Translation.tr("(you)") : "")
                        font.weight: participantRow.speaking ? Font.Bold : Font.Medium
                        color: participantRow.speaking ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
                    }
                    StyledText {
                        text: participantRow.speaking ? Translation.tr("Speaking") : Translation.tr("Listening")
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                    }
                    MaterialSymbol {
                        visible: participantRow.speaking
                        text: "volume_up"; iconSize: 15; color: Appearance.colors.colPrimary
                    }
                    MaterialSymbol {
                        visible: participantRow.muted
                        text: "mic_off"; iconSize: 15; color: Appearance.m3colors.m3error
                    }
                    MaterialSymbol {
                        visible: participantRow.deafened
                        text: "headset_off"; iconSize: 15; color: Appearance.m3colors.m3error
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    MaterialSymbol {
                        text: volumeSlider.value === 0
                            ? (participantRow.isSelf ? "mic_off" : "volume_off")
                            : (participantRow.isSelf ? "mic" : "volume_up")
                        iconSize: 13
                        color: Appearance.colors.colSubtext
                    }
                    StyledSlider {
                        id: volumeSlider
                        Layout.fillWidth: true
                        from: 0
                        to: participantRow.isSelf ? 100 : 200
                        stepSize: 1
                        enabled: !DiscordVoiceService.actionPending
                        value: participantRow.isSelf
                            ? DiscordVoiceService.micVolume
                            : (participantRow.participant?.volume ?? 100)
                        // Only send on release: upstream drafts the value while
                        // dragging and commits at the end.
                        onPressedChanged: {
                            if (pressed) return;
                            if (participantRow.isSelf) DiscordVoiceService.setMicVolume(value);
                            else DiscordVoiceService.setUserVolume(participantRow.participant.id, value);
                        }
                    }
                    StyledText {
                        Layout.preferredWidth: 38
                        horizontalAlignment: Text.AlignRight
                        text: `${Math.round(volumeSlider.value)}%`
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                    }
                }
            }
        }
    }
}
