pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    readonly property string ns: "sshMan"

    pluginId: "sshMan"

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Usage")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Hosts are parsed from ~/.ssh/config, Includes included; connect, test and copy act on the parsed list.")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Hosts added from the popout go into a managed block at the end of ~/.ssh/config, between marker comments. Everything outside that block is never touched, and a copy is kept at config.sshman.bak before each write.")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Live sessions are detected by polling the process table; sessions started in your own terminal show up there too.")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Scriptable: dms ipc call sshMan list | live | refresh | connect <alias> | files <alias> | test <alias> | add <alias> <host> [user] [port] | update <old> <new> <host> [user] [port] | remove <alias> | kill <pid>.")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Launcher")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StringSetting {
        settingKey: "trigger"
        label: I18n.trFor(root.ns, "Trigger")
        description: I18n.trFor(root.ns, "Prefix that activates the plugin in DankLauncher (e.g. !ssh).")
        placeholder: "!ssh"
        defaultValue: "!ssh"
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Connection")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StringSetting {
        settingKey: "terminalCommand"
        label: I18n.trFor(root.ns, "Terminal command")
        description: I18n.trFor(root.ns, "Override for the connect action; arguments are allowed and passed as argv. Leave empty to use the DMS default terminal, then $TERMINAL, then an installed terminal.")
        placeholder: "footclient"
        defaultValue: ""
    }

    SliderSetting {
        settingKey: "testTimeoutSeconds"
        label: I18n.trFor(root.ns, "Test timeout")
        description: I18n.trFor(root.ns, "ConnectTimeout for the BatchMode probe. Key-based auth only: a password prompt cannot be answered in the background.")
        defaultValue: 5
        minimum: 2
        maximum: 15
        unit: "s"
        leftIcon: "timer"
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "Sessions")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    SliderSetting {
        settingKey: "pollIntervalSeconds"
        label: I18n.trFor(root.ns, "Poll interval")
        description: I18n.trFor(root.ns, "How often the process table is read for live ssh sessions.")
        defaultValue: 5
        minimum: 2
        maximum: 60
        unit: "s"
        leftIcon: "timer"
    }

    ToggleSetting {
        settingKey: "notifyOnNewSession"
        label: I18n.trFor(root.ns, "New session notification")
        description: I18n.trFor(root.ns, "Announce when a new ssh session is detected.")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "notifyOnSessionEnd"
        label: I18n.trFor(root.ns, "Session end notification")
        description: I18n.trFor(root.ns, "Announce when a session disappears. Off by default: the popout already shows the live list.")
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "showUnresolved"
        label: I18n.trFor(root.ns, "Unmatched sessions")
        description: I18n.trFor(root.ns, "Also list ssh processes that match no known host, so stray sessions are still visible.")
        defaultValue: true
    }

    StyledText {
        width: parent.width
        text: I18n.trFor(root.ns, "File manager")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "notifyOnTransferComplete"
        label: I18n.trFor(root.ns, "Transfer notification")
        description: I18n.trFor(root.ns, "Announce when a batch of file transfers finishes. Browsing and transferring need key authentication (BatchMode); password hosts can still be used via the connect action.")
        defaultValue: true
    }
}
