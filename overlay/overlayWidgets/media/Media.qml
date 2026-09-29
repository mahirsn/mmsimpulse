pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.ii.overlay

// The media popup's player, for whatever is playing, over a game.
StyledOverlayWidget {
    id: root
    title: Translation.tr("Media")
    minimumWidth: Appearance.sizes.mediaControlsWidth
    minimumHeight: Appearance.sizes.mediaControlsHeight

    contentItem: OverlayBackground {
        id: contentItem
        radius: root.contentRadius

        Loader {
            anchors.fill: parent
            active: MprisController.activePlayer !== null
            sourceComponent: Player {
                player: MprisController.activePlayer
                radius: root.contentRadius
            }
        }

        PagePlaceholder {
            shown: MprisController.activePlayer === null
            icon: "music_off"
            title: Translation.tr("Nothing playing")
            shape: MaterialShape.Shape.Ghostish
        }
    }
}
