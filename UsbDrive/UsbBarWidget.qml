pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

/**
 * DankBar entry for usbDrive. Shows a USB glyph with a mounted-volume badge;
 * the popout gives one card per drive, a mount switch and usage bar per volume,
 * and a safe-remove action per drive. State is read straight off the daemon
 * instance (same pattern as dms-shotrec), so there is no IPC round-trip in the
 * UI path.
 */
PluginComponent {
    id: root

    readonly property string ns: "usbDrive"

    readonly property var daemon: root.pluginService
        ? root.pluginService.pluginDaemonInstances["usbDrive"] ?? null : null
    readonly property var driveList: root.daemon ? root.daemon.drives : []
    readonly property int mountedVolumes: {
        let total = 0;
        root.driveList.forEach(drive => {
            total += drive.mountedCount;
        });
        return total;
    }

    readonly property bool showCount: pluginData.showCount !== false
    readonly property bool showLabel: pluginData.showLabel === true
    readonly property bool hasDrives: root.driveList.length > 0
    readonly property int pillIconSize: root.widgetThickness > 0
        ? Math.floor(root.widgetThickness * 0.55) : Theme.iconSize

    component DriveGlyph: Column {
        spacing: Theme.spacingXXS

        Rectangle {
            visible: root.showCount && root.mountedVolumes > 0
            width: Math.max(badgeText.implicitWidth + 6, 14)
            height: 14
            radius: 7
            color: Theme.primary
            anchors.horizontalCenter: parent.horizontalCenter

            StyledText {
                id: badgeText
                anchors.centerIn: parent
                text: String(root.mountedVolumes)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.primaryText
            }
        }

        DankIcon {
            name: root.hasDrives ? "usb" : "usb_off"
            size: root.pillIconSize
            color: root.hasDrives ? Theme.primary : Theme.surfaceVariantText
        }

        StyledText {
            visible: root.showLabel && root.hasDrives
            text: String(root.driveList.length)
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    component ToolButton: Rectangle {
        id: tool

        property string iconName: ""
        property string label: ""
        property color accent: Theme.primary

        // Must stay a signal named `tap` so call sites read `onTap: {}`.
        // Declaring `property var onTap` and assigning a `{ ... }` block instead
        // makes QML run that block as a binding at object creation: every
        // delegate executed its action on panel open, so ejectDrive() issued
        // udisksctl power-off for all drives the instant the popout appeared.
        signal tap

        width: tool.label !== "" ? toolRow.implicitWidth + Theme.spacingS * 2 : 28
        height: 26
        radius: Theme.cornerRadius
        color: toolArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
        border.width: 1
        border.color: toolArea.containsMouse ? Theme.outline : "transparent"
        // Item.enabled already blocks the MouseArea; this makes the wait visible.
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

    // ---- Display helpers ---------------------------------------------------

    /// A volume that is not mounted has no usage figure at all, so the caller
    /// must not be handed a zero to draw: an empty bar reads as "formatted and
    /// empty", which is a different claim from "we never asked".
    function volumeFraction(partition) {
        if (partition.mountpoint === "" || !(partition.totalBytes > 0))
            return -1;
        const percent = partition.usagePercent >= 0
            ? partition.usagePercent
            : partition.usedBytes / partition.totalBytes * 100;
        return Math.min(1.0, Math.max(0.0, percent / 100));
    }

    function volumeCaption(partition) {
        if (partition.mountpoint === "")
            return partition.fstype === ""
                ? I18n.trFor(root.ns, "No supported filesystem")
                : I18n.trFor(root.ns, "Not mounted");
        if (partition.usagePercent < 0 && !(partition.totalBytes > 0))
            return I18n.trFor(root.ns, "No usage data");
        const percent = partition.usagePercent >= 0
            ? partition.usagePercent
            : Math.round(partition.usedBytes / partition.totalBytes * 100);
        return I18n.trFor(root.ns, "%1 used of %2 · %3%")
            .arg(root.daemon ? root.daemon.humanSize(partition.usedBytes) : "")
            .arg(root.daemon ? root.daemon.humanSize(partition.totalBytes) : "")
            .arg(percent);
    }

    function driveFraction(drive) {
        if (!(drive.totalBytes > 0))
            return -1;
        return Math.min(1.0, Math.max(0.0, drive.usedBytes / drive.totalBytes));
    }

    function barColor(fraction) {
        if (fraction > 0.90)
            return Theme.error;
        if (fraction > 0.75)
            return Theme.warning;
        return Theme.primary;
    }

    function driveCaption(drive) {
        let text = I18n.trFor(root.ns, "%1 of %2 mounted")
            .arg(drive.mountedCount)
            .arg(drive.partitionCount);
        if (drive.totalBytes > 0) {
            text += " · " + I18n.trFor(root.ns, "%1 of %2 used")
                .arg(root.daemon ? root.daemon.humanSize(drive.usedBytes) : "")
                .arg(root.daemon ? root.daemon.humanSize(drive.totalBytes) : "");
        }
        return text;
    }

    function driveDetails(drive) {
        const transport = drive.tran !== "" ? drive.tran.toUpperCase()
            : I18n.trFor(root.ns, "Removable");
        return `${drive.path} · ${transport}`;
    }

    function volumeMeta(partition) {
        const bits = [];
        if (partition.fstype !== "")
            bits.push(partition.fstype.toUpperCase());
        if (partition.size > 0 && root.daemon)
            bits.push(root.daemon.humanSize(partition.size));
        if (partition.mountpoint !== "")
            bits.push(partition.mountpoint);
        return bits.join(" · ");
    }

    horizontalBarPill: Component {
        DriveGlyph {}
    }

    verticalBarPill: Component {
        DriveGlyph {}
    }

    popoutContent: Component {
        PopoutComponent {
            id: panel

            headerText: I18n.trFor(root.ns, "USB Drive")
            detailsText: {
                if (!root.daemon)
                    return I18n.trFor(root.ns, "Daemon is not running");
                if (!root.daemon.monitorAvailable)
                    return I18n.trFor(root.ns, "udev monitor unavailable — use refresh");
                if (root.daemon.lastScanAt === "")
                    return I18n.trFor(root.ns, "Scanning…");
                return I18n.trFor(root.ns, "Plug and unplug detected automatically · last scan %1")
                    .arg(root.daemon.lastScanAt);
            }
            showCloseButton: true

            headerActions: Component {
                ToolButton {
                    iconName: "refresh"
                    onTap: {
                        if (root.daemon)
                            root.daemon.rescan();
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
                    contentHeight: driveColumn.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true
                    visible: root.hasDrives

                    Column {
                        id: driveColumn
                        width: scroller.width
                        spacing: Theme.spacingS

                        Repeater {
                            model: root.driveList

                            delegate: StyledRect {
                                id: card

                                required property var modelData

                                // activeJobs is read here rather than through a daemon
                                // helper on purpose: the binding is only invalidated if
                                // the property itself is accessed while it is evaluated.
                                readonly property bool jobRunning: root.daemon
                                    ? root.daemon.activeJobs.filter(entry => {
                                        const device = entry.substring(entry.indexOf(":") + 1);
                                        return device === card.modelData.name || card.modelData.partitions
                                            .some(partition => partition.name === device);
                                    }).length > 0
                                    : false
                                readonly property real fraction: root.driveFraction(card.modelData)

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
                                            width: parent.width - cardEject.width - Theme.spacingS
                                            spacing: 2

                                            StyledText {
                                                width: parent.width
                                                text: root.daemon
                                                    ? root.daemon.driveTitle(card.modelData) : card.modelData.name
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.DemiBold
                                                color: Theme.surfaceText
                                                elide: Text.ElideRight
                                            }

                                            StyledText {
                                                width: parent.width
                                                text: root.daemon ? root.daemon.driveSubtitle(card.modelData) : ""
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                elide: Text.ElideRight
                                            }
                                        }

                                        ToolButton {
                                            id: cardEject
                                            anchors.top: parent.top
                                            iconName: "eject"
                                            label: I18n.trFor(root.ns, "Safely remove")
                                            accent: Theme.error
                                            enabled: !card.jobRunning
                                            onTap: {
                                                if (root.daemon)
                                                    root.daemon.ejectDrive(card.modelData.name);
                                            }
                                        }
                                    }

                                    // Drive-level usage covers the mounted volumes only:
                                    // an unmounted filesystem has nothing to add up.
                                    StyledText {
                                        width: parent.width
                                        text: root.driveCaption(card.modelData)
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: card.fraction > 0.90 ? Theme.error
                                            : (card.fraction > 0.75 ? Theme.warning : Theme.surfaceVariantText)
                                    }

                                    Rectangle {
                                        visible: card.fraction >= 0
                                        width: parent.width
                                        height: 6
                                        radius: 3
                                        color: Theme.surfaceContainerHighest

                                        Rectangle {
                                            width: card.fraction * parent.width
                                            height: parent.height
                                            radius: parent.radius
                                            color: root.barColor(card.fraction)
                                        }
                                    }

                                    Repeater {
                                        model: card.modelData.partitions

                                        delegate: Row {
                                            id: volume

                                            required property var modelData

                                            readonly property real fraction: root.volumeFraction(volume.modelData)
                                            readonly property bool mountable: volume.modelData.fstype !== ""
                                            readonly property bool jobRunning: root.daemon
                                                ? (root.daemon.activeJobs.indexOf("mount:" + volume.modelData.name) >= 0
                                                    || root.daemon.activeJobs.indexOf("unmount:" + volume.modelData.name) >= 0)
                                                : false

                                            width: parent.width
                                            spacing: Theme.spacingS

                                            Column {
                                                width: parent.width - volumeActions.width - Theme.spacingS
                                                spacing: 2

                                                StyledText {
                                                    width: parent.width
                                                    text: root.daemon
                                                        ? root.daemon.partitionName(volume.modelData)
                                                        : volume.modelData.name
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: volume.modelData.mountpoint !== ""
                                                        ? Theme.surfaceText : Theme.surfaceVariantText
                                                    elide: Text.ElideRight
                                                }

                                                StyledText {
                                                    width: parent.width
                                                    text: root.volumeMeta(volume.modelData)
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: volume.modelData.mountpoint !== ""
                                                        ? Theme.primary : Theme.surfaceVariantText
                                                    elide: Text.ElideMiddle
                                                }

                                                Rectangle {
                                                    visible: volume.fraction >= 0
                                                    width: parent.width
                                                    height: 5
                                                    radius: 2
                                                    color: Theme.surfaceContainerHighest

                                                    Rectangle {
                                                        width: volume.fraction * parent.width
                                                        height: parent.height
                                                        radius: parent.radius
                                                        color: root.barColor(volume.fraction)
                                                    }
                                                }

                                                StyledText {
                                                    visible: volume.mountable
                                                    width: parent.width
                                                    text: root.volumeCaption(volume.modelData)
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: Theme.surfaceVariantText
                                                    elide: Text.ElideMiddle
                                                }
                                            }

                                            Row {
                                                id: volumeActions
                                                spacing: Theme.spacingXS

                                                ToolButton {
                                                    visible: volume.mountable
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    iconName: "folder_open"
                                                    enabled: !volume.jobRunning
                                                    onTap: {
                                                        if (root.daemon)
                                                            root.daemon.requestOpenPartition(volume.modelData.name);
                                                    }
                                                }

                                                DankToggle {
                                                    visible: volume.mountable
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: 52
                                                    height: 30

                                                    // The thumb is driven by lsblk, never by the
                                                    // click: DankToggle does not flip checked
                                                    // itself, so it only moves once udisks actually
                                                    // mounted the volume.
                                                    checked: volume.modelData.mountpoint !== ""
                                                    toggling: volume.jobRunning
                                                    enabled: !volume.jobRunning
                                                    onClicked: {
                                                        if (!root.daemon || volume.jobRunning)
                                                            return;
                                                        if (volume.modelData.mountpoint !== "")
                                                            root.daemon.unmountPartition(volume.modelData.name);
                                                        else
                                                            root.daemon.mountPartition(volume.modelData.name);
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: root.driveDetails(card.modelData)
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideMiddle
                                    }
                                }
                            }
                        }
                    }
                }

                Column {
                    anchors.fill: parent
                    spacing: Theme.spacingXS
                    visible: !root.hasDrives

                    StyledText {
                        width: parent.width
                        text: I18n.trFor(root.ns, "No USB drives detected")
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                    }

                    StyledText {
                        width: parent.width
                        text: I18n.trFor(root.ns, "Plug one in and it shows up here automatically.")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }

    popoutWidth: 460
    popoutHeight: 520
}
