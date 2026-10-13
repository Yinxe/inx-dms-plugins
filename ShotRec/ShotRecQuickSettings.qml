pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

/**
 * Compact settings panel shown in the bar pill's right-click popout:
 * a thin shell around the shared tabbed ShotRecConfigPanel. The panel must
 * stay a direct content child (PluginSettings only refreshes those).
 */
PluginSettings {
    id: root

    pluginId: "shotrec"
    pluginService: PluginService

    Row {
        width: parent.width
        spacing: Theme.spacingS

        DankIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: "tune"
            size: Theme.iconSizeSmall
            color: Theme.surfaceVariantText
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: I18n.trFor("shotrec", "Quick settings")
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.DemiBold
            color: Theme.surfaceText
        }
    }

    ShotRecConfigPanel {
        width: parent.width
    }
}
