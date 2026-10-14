pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

/**
 * DankBar entry for sshMan. Shows a terminal glyph with a live-session badge;
 * the popout lists parsed hosts with connect/test/copy actions, an inline
 * form for managed hosts, and the live ssh session table with terminate
 * buttons. State is read straight off the daemon instance (same pattern as
 * usbDrive), so there is no IPC round-trip in the UI path.
 */
PluginComponent {
    id: root

    readonly property string ns: "sshMan"

    readonly property var daemon: root.pluginService
        ? root.pluginService.pluginDaemonInstances["sshMan"] ?? null : null
    readonly property var hostList: root.daemon ? root.daemon.hosts : []
    readonly property var sessionList: root.daemon ? root.daemon.sessions : []
    readonly property bool hasHosts: root.hostList.length > 0
    readonly property int liveCount: {
        let total = 0;
        root.sessionList.forEach(session => {
            if (session.kind === "session")
                total += 1;
        });
        return total;
    }

    readonly property int pillIconSize: root.widgetThickness > 0
        ? Math.floor(root.widgetThickness * 0.55) : Theme.iconSize

    // Add-form feedback; cleared whenever the form is submitted again.
    property string formStatus: ""

    // Whether the (collapsed by default) add form is expanded. Edit taps set
    // editingAlias instead, which expands the same form in update mode.
    property bool formOpen: false

    // Non-empty while the form edits that managed host instead of adding one.
    // Lives here rather than in the panel because the popout content is
    // recreated on every open, and a half-filled edit form must not survive
    // that as an apparent "editing" state with empty fields.
    property string editingAlias: ""

    component ToolButton: Rectangle {
        id: tool

        property string iconName: ""
        property string label: ""
        property color accent: Theme.primary

        // Must stay a signal named `tap` so call sites read `onTap: {}`.
        // A `property var onTap` assigned a block would run as a binding at
        // object creation and fire every action the instant the panel opens.
        signal tap

        width: tool.label !== "" ? toolRow.implicitWidth + Theme.spacingS * 2 : 28
        height: 26
        radius: Theme.cornerRadius
        color: toolArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
        border.width: 1
        border.color: toolArea.containsMouse ? Theme.outline : "transparent"
        opacity: tool.enabled ? 1.0 : 0.4

        Row {
            id: toolRow
            anchors.centerIn: parent
            spacing: Theme.spacingXS

            DankIcon {
                visible: tool.iconName !== ""
                anchors.verticalCenter: parent.verticalCenter
                name: tool.iconName
                size: Theme.iconSizeSmall
                color: toolArea.containsMouse ? tool.accent : Theme.surfaceVariantText
            }

            StyledText {
                visible: tool.label !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: tool.label
                font.pixelSize: Theme.fontSizeSmall
                color: toolArea.containsMouse ? tool.accent : Theme.surfaceText
            }
        }

        MouseArea {
            id: toolArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tool.tap()
        }
    }

    component Pill: Column {
        spacing: Theme.spacingXXS

        Rectangle {
            visible: root.liveCount > 0
            width: Math.max(badgeText.implicitWidth + 6, 14)
            height: 14
            radius: 7
            color: Theme.primary
            anchors.horizontalCenter: parent.horizontalCenter

            StyledText {
                id: badgeText
                anchors.centerIn: parent
                text: String(root.liveCount)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.primaryText
            }
        }

        DankIcon {
            name: "terminal"
            size: root.pillIconSize
            color: root.hasHosts || root.liveCount > 0
                ? Theme.primary : Theme.surfaceVariantText
        }
    }

    horizontalBarPill: Component {
        Pill {}
    }

    verticalBarPill: Component {
        Pill {}
    }

    popoutContent: Component {
        PopoutComponent {
            id: panel

            // A fresh panel starts as the collapsed add trigger; carrying a
            // stale editingAlias into it would submit against invisible fields.
            Component.onCompleted: {
                root.formOpen = false;
                root.editingAlias = "";
                root.formStatus = "";
            }

            // One place to fold the form back down and blank it, shared by
            // the close button, the cancel path and the write-landed signal.
            function resetForm() {
                root.formOpen = false;
                root.editingAlias = "";
                root.formStatus = "";
                aliasField.text = "";
                hostField.text = "";
                userField.text = "";
                portField.text = "";
            }

            headerText: I18n.trFor(root.ns, "SSH Manager")
            detailsText: {
                if (!root.daemon)
                    return I18n.trFor(root.ns, "Daemon is not running");
                if (!root.daemon.configExists)
                    return I18n.trFor(root.ns, "No ssh_config yet — add a host below");
                if (root.daemon.warnings.length > 0)
                    return I18n.trFor(root.ns, "%1 hosts · %2 config warnings")
                        .arg(root.hostList.length).arg(root.daemon.warnings.length);
                return I18n.trFor(root.ns, "%1 hosts · last parsed %2")
                    .arg(root.hostList.length).arg(root.daemon.lastParseAt);
            }
            showCloseButton: true

            headerActions: Component {
                ToolButton {
                    iconName: "refresh"
                    onTap: {
                        if (root.daemon)
                            root.daemon.reloadConfig();
                    }
                }
            }

            // Remaining body height after header and description.
            Item {
                width: panel.width
                height: root.popoutHeight - panel.headerHeight - panel.detailsHeight
                    - Theme.spacingXL * 2

                DankFlickable {
                    id: scroller

                    anchors.fill: parent
                    contentHeight: bodyColumn.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true

                    Column {
                        id: bodyColumn
                        width: scroller.width
                        spacing: Theme.spacingM

                        // ---- Hosts ------------------------------------------
                        Repeater {
                            model: root.hostList

                            delegate: StyledRect {
                                id: card

                                required property var modelData

                                readonly property var host: card.modelData
                                readonly property bool busy: root.daemon
                                    ? root.daemon.activeOps.some(entry =>
                                        entry.substring(entry.indexOf(":") + 1) === host.alias)
                                    : false
                                readonly property var test: root.daemon
                                    ? root.daemon.testResults[host.alias] ?? null : null

                                width: parent.width
                                height: cardColumn.implicitHeight + Theme.spacingM * 2
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainerHigh

                                Column {
                                    id: cardColumn
                                    x: Theme.spacingM
                                    y: Theme.spacingM
                                    width: parent.width - Theme.spacingM * 2
                                    spacing: Theme.spacingXS

                                    Row {
                                        width: parent.width
                                        spacing: Theme.spacingS

                                        Column {
                                            width: parent.width - cardActions.width - Theme.spacingS
                                            spacing: 2

                                            StyledText {
                                                width: parent.width
                                                text: host.alias
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.DemiBold
                                                color: Theme.surfaceText
                                                elide: Text.ElideRight
                                            }

                                            StyledText {
                                                width: parent.width
                                                text: root.daemon
                                                    ? root.daemon.hostSubtitle(host) : ""
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: host.wildcard ? Theme.surfaceVariantText
                                                    : Theme.surfaceText
                                                elide: Text.ElideMiddle
                                            }
                                        }

                                        Row {
                                            id: cardActions
                                            spacing: Theme.spacingXS

                                            ToolButton {
                                                anchors.verticalCenter: parent.verticalCenter
                                                iconName: "link"
                                                accent: Theme.primary
                                                enabled: !card.busy && !host.wildcard
                                                onTap: {
                                                    if (root.daemon)
                                                        root.daemon.openSession(host.alias);
                                                }
                                            }

                                            ToolButton {
                                                anchors.verticalCenter: parent.verticalCenter
                                                iconName: "network_check"
                                                enabled: !card.busy && !host.wildcard
                                                onTap: {
                                                    if (root.daemon)
                                                        root.daemon.testHost(host.alias);
                                                }
                                            }

                                            ToolButton {
                                                anchors.verticalCenter: parent.verticalCenter
                                                iconName: "content_copy"
                                                enabled: !host.wildcard
                                                onTap: {
                                                    if (root.daemon)
                                                        root.daemon.copyCommand(host.alias);
                                                }
                                            }

                                            ToolButton {
                                                anchors.verticalCenter: parent.verticalCenter
                                                iconName: "folder"
                                                enabled: !host.wildcard
                                                onTap: {
                                                    if (root.daemon)
                                                        root.daemon.openFiles(host.alias);
                                                }
                                            }

                                            ToolButton {
                                                visible: host.managed
                                                anchors.verticalCenter: parent.verticalCenter
                                                iconName: "edit"
                                                enabled: !card.busy
                                                // Seed the form with this host's values and
                                                // switch it to update mode; the submit button
                                                // and header follow editingAlias.
                                                onTap: {
                                                    root.editingAlias = host.alias;
                                                    aliasField.text = host.alias;
                                                    hostField.text = host.hostname;
                                                    userField.text = host.user;
                                                    portField.text = host.port !== "22"
                                                        ? String(host.port) : "";
                                                    root.formStatus = "";
                                                }
                                            }

                                            ToolButton {
                                                visible: host.managed
                                                anchors.verticalCenter: parent.verticalCenter
                                                iconName: "delete"
                                                accent: Theme.error
                                                enabled: !card.busy
                                                onTap: {
                                                    if (root.daemon)
                                                        root.daemon.removeHost(host.alias);
                                                }
                                            }
                                        }
                                    }

                                    Row {
                                        visible: card.test !== null || host.wildcard
                                            || host.managed || host.proxyJump !== ""
                                        spacing: Theme.spacingXS

                                        Rectangle {
                                            visible: host.managed
                                            width: managedText.implicitWidth + 10
                                            height: 16
                                            radius: 8
                                            color: Theme.surfaceContainerHighest

                                            StyledText {
                                                id: managedText
                                                anchors.centerIn: parent
                                                text: I18n.trFor(root.ns, "managed")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                            }
                                        }

                                        Rectangle {
                                            visible: host.wildcard
                                            width: templateText.implicitWidth + 10
                                            height: 16
                                            radius: 8
                                            color: Theme.surfaceContainerHighest

                                            StyledText {
                                                id: templateText
                                                anchors.centerIn: parent
                                                text: I18n.trFor(root.ns, "template")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                            }
                                        }
                                    }

                                    StyledText {
                                        visible: card.test !== null
                                        width: parent.width
                                        text: card.test !== null
                                            ? (card.test.ok
                                                ? I18n.trFor(root.ns, "Reachable")
                                                : I18n.trFor(root.ns, "Unreachable"))
                                                + " · " + card.test.at
                                            : ""
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: card.test !== null && card.test.ok
                                            ? Theme.success : Theme.error
                                        wrapMode: Text.WordWrap
                                    }

                                    StyledText {
                                        visible: card.test !== null && !card.test.ok
                                            && card.test.message !== ""
                                        width: parent.width
                                        text: card.test !== null ? card.test.message : ""
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: !root.hasHosts

                            StyledText {
                                width: parent.width
                                text: I18n.trFor(root.ns, "No SSH hosts configured")
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceText
                            }

                            StyledText {
                                width: parent.width
                                text: I18n.trFor(root.ns,
                                    "Add one below, or edit ~/.ssh/config and press refresh.")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                            }
                        }

                        // ---- Add host ----------------------------------------
                        // Collapsed to a single trigger by default; expands
                        // for adding or editing so the popout is not a wall
                        // of always-visible inputs.
                        ToolButton {
                            id: addTrigger

                            visible: !root.formOpen && root.editingAlias === ""
                            label: I18n.trFor(root.ns, "Add host")
                            iconName: "add"
                            enabled: root.daemon !== null
                            onTap: root.formOpen = true
                        }

                        StyledRect {
                            id: addBox

                            readonly property bool expanded:
                                root.formOpen || root.editingAlias !== ""

                            visible: expanded
                            width: parent.width
                            height: addColumn.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh

                            Column {
                                id: addColumn
                                x: Theme.spacingM
                                y: Theme.spacingM
                                width: parent.width - Theme.spacingM * 2
                                spacing: Theme.spacingS

                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingS

                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - closeTool.width - Theme.spacingS
                                        text: root.editingAlias === ""
                                            ? I18n.trFor(root.ns, "Add managed host")
                                            : I18n.trFor(root.ns, "Edit managed host")
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                    }

                                    ToolButton {
                                        id: closeTool
                                        anchors.verticalCenter: parent.verticalCenter
                                        iconName: "close"
                                        onTap: panel.resetForm()
                                    }
                                }

                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingS

                                    DankTextField {
                                        id: aliasField

                                        width: (parent.width - Theme.spacingS) / 2
                                        placeholderText: I18n.trFor(root.ns, "Alias")
                                        maximumLength: 64
                                    }

                                    DankTextField {
                                        id: hostField

                                        width: (parent.width - Theme.spacingS) / 2
                                        placeholderText: I18n.trFor(root.ns, "Host name")
                                        maximumLength: 253
                                    }
                                }

                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingS

                                    DankTextField {
                                        id: userField

                                        width: (parent.width - Theme.spacingS) * 0.6
                                        placeholderText: I18n.trFor(root.ns, "User (optional)")
                                        maximumLength: 64
                                    }

                                    DankTextField {
                                        id: portField

                                        width: (parent.width - Theme.spacingS) * 0.4
                                        placeholderText: I18n.trFor(root.ns, "Port (optional)")
                                        maximumLength: 5
                                        validator: IntValidator {
                                            bottom: 1
                                            top: 65535
                                        }
                                    }
                                }

                                Row {
                                    spacing: Theme.spacingS

                                    ToolButton {
                                        id: addTool
                                        iconName: root.editingAlias === "" ? "add" : "check"
                                        label: root.editingAlias === ""
                                            ? I18n.trFor(root.ns, "Add host")
                                            : I18n.trFor(root.ns, "Save changes")
                                        enabled: root.daemon !== null
                                            && aliasField.text.trim() !== ""
                                            && hostField.text.trim() !== ""
                                        onTap: {
                                            if (!root.daemon)
                                                return;
                                            const alias = aliasField.text.trim();
                                            root.formStatus = root.editingAlias === ""
                                                ? root.daemon.addHost(alias,
                                                    hostField.text.trim(),
                                                    userField.text.trim(),
                                                    portField.text.trim())
                                                : root.daemon.updateHost(root.editingAlias,
                                                    alias, hostField.text.trim(),
                                                    userField.text.trim(),
                                                    portField.text.trim());
                                            // Clearing waits for the daemon's hostWritten
                                            // signal: the write is async, so the list is
                                            // not updated yet at this point.
                                        }
                                    }
                                }

                                StyledText {
                                    visible: root.formStatus !== ""
                                    width: parent.width
                                    text: root.formStatus
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }

                        // The daemon reparses after every managed write; on that
                        // signal the form has durably landed, so fold it back to
                        // the collapsed trigger (including an in-flight edit).
                        Connections {
                            target: root.daemon

                            function onHostWritten(_alias) {
                                panel.resetForm();
                            }
                        }

                        // ---- Live sessions -------------------------------------
                        Column {
                            width: parent.width
                            visible: root.sessionList.length > 0
                            spacing: Theme.spacingXS

                            StyledText {
                                width: parent.width
                                text: I18n.trFor(root.ns, "Live sessions")
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.DemiBold
                                color: Theme.surfaceText
                            }

                            Repeater {
                                model: root.sessionList

                                delegate: StyledRect {
                                    id: row

                                    required property var modelData

                                    readonly property var session: row.modelData

                                    width: parent.width
                                    height: sessionRow.implicitHeight + Theme.spacingS * 2
                                    radius: Theme.cornerRadius
                                    color: Theme.surfaceContainerHigh

                                    Row {
                                        id: sessionRow
                                        x: Theme.spacingS
                                        y: Theme.spacingS
                                        width: parent.width - Theme.spacingS * 2
                                        spacing: Theme.spacingS

                                        DankIcon {
                                            id: sessionIcon
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: session.kind === "master"
                                                ? "bolt" : "link"
                                            size: Theme.iconSizeSmall
                                            color: session.connected ? Theme.primary
                                                : Theme.surfaceVariantText
                                        }

                                        Column {
                                            // Subtract both gaps and the icon too:
                                            // missing the icon is what pushed the kill
                                            // button past the card's right edge.
                                            width: parent.width - sessionIcon.width
                                                - killTool.width - Theme.spacingS * 2
                                            spacing: 2

                                            StyledText {
                                                width: parent.width
                                                text: session.alias !== ""
                                                    ? session.alias : session.target
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                                elide: Text.ElideRight
                                            }

                                            StyledText {
                                                width: parent.width
                                                text: (session.target !== "" ? session.target
                                                    : I18n.trFor(root.ns, "unknown target"))
                                                    + " · pid " + session.pid + " · "
                                                    + (root.daemon
                                                        ? root.daemon.humanEtime(session.etime)
                                                        : "")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                elide: Text.ElideMiddle
                                            }
                                        }

                                        ToolButton {
                                            id: killTool
                                            anchors.verticalCenter: parent.verticalCenter
                                            iconName: "close"
                                            accent: Theme.error
                                            onTap: {
                                                if (root.daemon)
                                                    root.daemon.killSession(session.pid);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 480
    popoutHeight: 560
}
