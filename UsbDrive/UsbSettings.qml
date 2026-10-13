pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    readonly property string ns: "usbDrive"

    pluginId: "usbDrive"

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Usage")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "The daemon subscribes to udev block events, so plug and unplug are detected without polling.")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "The bar pill counts mounted volumes. Each drive gets a card with a mount switch and a usage bar per volume, plus a safe-remove action that unmounts every volume before cutting power.")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Events are posted to the DMS notification center over org.freedesktop.Notifications.")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Scriptable: dms ipc call usbDrive list | rescan | eject sdb | unmount sdb1 | open sdb1.")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Detection")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    SelectionSetting {
        settingKey: "matchMode"
        label: I18n.trFor(root.ns, "Drive filter")
        description: I18n.trFor(root.ns, "USB transport only, anything the kernel flags removable, or both.")
        options: [
            {
                label: I18n.trFor(root.ns, "USB or removable"),
                value: "any"
            },
            {
                label: I18n.trFor(root.ns, "USB transport only"),
                value: "usb"
            },
            {
                label: I18n.trFor(root.ns, "Removable flag only"),
                value: "removable"
            }
        ]
        defaultValue: "any"
    }

    SliderSetting {
        settingKey: "scanDebounceMs"
        label: I18n.trFor(root.ns, "Scan debounce")
        description: I18n.trFor(root.ns, "Wait after a plug event before reading lsblk, so partitions settle.")
        defaultValue: 800
        minimum: 200
        maximum: 3000
        unit: "ms"
        leftIcon: "timer"
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Notifications")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "notifyPlugEvents"
        label: I18n.trFor(root.ns, "Plug and unplug")
        description: I18n.trFor(root.ns, "Announce when a drive appears or is pulled out.")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "notifyMountEvents"
        label: I18n.trFor(root.ns, "Mount and unmount")
        description: I18n.trFor(root.ns, "Announce volume mount points, which udisks usually mounts a second later. Off by default: the card shows this state directly.")
        defaultValue: false
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Mount behaviour")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "autoMount"
        label: I18n.trFor(root.ns, "Auto-mount on plug")
        description: I18n.trFor(root.ns, "Mount one volume per freshly plugged drive: the largest one with a usable filesystem, which is the data partition on sticks that also carry an EFI or recovery sliver.")
        defaultValue: false
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Bar widget")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "showCount"
        label: I18n.trFor(root.ns, "Mounted volume badge")
        description: I18n.trFor(root.ns, "Show how many volumes are mounted on the pill.")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showLabel"
        label: I18n.trFor(root.ns, "Drive count")
        description: I18n.trFor(root.ns, "Also print the number of detected drives under the icon.")
        defaultValue: false
    }

    StringSetting {
        settingKey: "fileManagerApp"
        label: I18n.trFor(root.ns, "File manager")
        description: I18n.trFor(root.ns, "Command prefix for the open action; arguments are allowed and passed without a shell. Leave empty to use the default file manager, falling back to the default terminal.")
        placeholder: "thunar"
        defaultValue: ""
    }
}
