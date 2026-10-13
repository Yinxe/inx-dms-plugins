pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root

    pluginId: "shotrec"

    // Direct content children only: PluginSettings re-reads `loadValue()` on
    // its immediate children after injecting pluginService, so nothing here
    // may sit inside a wrapper item.

    StyledText {
        width: parent.width
        text: I18n.trFor("shotrec", "Shot & Rec")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: I18n.trFor("shotrec", "Print opens the picker with the frozen screen, always starting on the Screenshot mode. Left/Right or clicking a chip switches mode, drag selects a region, Enter confirms, Esc cancels. Press the same hotkey again to stop a recording.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    ShotRecConfigPanel {
        width: parent.width
    }

    StyledText {
        width: parent.width
        text: I18n.trFor("shotrec", "IPC commands")
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.DemiBold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: `dms ipc call shotrec toggle
dms ipc call shotrec setMode shot
dms ipc call shotrec setMode windowShot
dms ipc call shotrec setMode record
dms ipc call shotrec stop
dms ipc call shotrec status
dms ipc call shotrec shotNow ""
dms ipc call shotrec recordNow ""`
        font.pixelSize: Theme.fontSizeSmall
        font.family: Fonts.mono
        color: Theme.surfaceVariantText
        wrapMode: Text.NoWrap
    }
}
