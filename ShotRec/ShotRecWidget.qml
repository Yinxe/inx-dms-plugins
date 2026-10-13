pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

/**
 * DankBar entry for Shot & Rec. Click toggles the picker (or stops a running
 * recording); shows a blinking REC dot and elapsed time while recording.
 * Reads the daemon instance directly through PluginService, no IPC round-trip.
 */
PluginComponent {
    id: root

    pluginId: "shotrec"
    pluginService: PluginService

    readonly property var daemon: PluginService.pluginDaemonInstances[pluginId] ?? null
    readonly property bool recording: root.daemon?.phase === "recording"

    readonly property string timeText: {
        const seconds = root.daemon ? Number(root.daemon.recordSeconds) : 0;
        const m = Math.floor(seconds / 60);
        const s = seconds % 60;
        return `${m}:${String(s).padStart(2, "0")}`;
    }

    readonly property int iconSize: root.widgetThickness > 0 ? Math.floor(root.widgetThickness * 0.6) : Theme.iconSizeNormal

    pillClickAction: () => {
        if (root.daemon)
            root.daemon.toggle();
    }

    PluginPopout {
        id: quickPopout

        contentWidth: 340
        pluginContent: Component {
            ShotRecQuickSettings {}
        }
    }

    // PluginComponent.triggerPopout() short-circuits into pillClickAction, so
    // open our own popout with the same position math the base does.
    function openQuickSettings() {
        const globalPos = root.mapToItem(null, 0, 0);
        const currentScreen = root.parentScreen || Screen;
        const barPosition = root.axis?.edge === "left" ? 2 : (root.axis?.edge === "right" ? 3 : (root.axis?.edge === "top" ? 0 : 1));
        const pos = SettingsData.getPopupTriggerPosition(globalPos, currentScreen, root.barThickness, root.width, root.barSpacing, barPosition, root.barConfig);
        quickPopout.setTriggerPosition(pos.x, pos.y, pos.width, root.section, currentScreen, barPosition, root.barThickness, root.barSpacing, root.barConfig);
        quickPopout.toggle();
    }

    pillRightClickAction: () => root.openQuickSettings()

    Connections {
        target: root.daemon
        enabled: root.daemon !== null
        function onQuickSettingsPingChanged() {
            root.openQuickSettings();
        }
    }

    component RecDot: Rectangle {
        width: Theme.spacingS
        height: width
        radius: width / 2
        color: Theme.error
        visible: root.recording

        SequentialAnimation on opacity {
            running: root.recording
            loops: Animation.Infinite
            NumberAnimation {
                to: 0.2
                duration: 600
                easing.type: Theme.standardEasing
            }
            NumberAnimation {
                to: 1.0
                duration: 600
                easing.type: Theme.standardEasing
            }
        }
    }

    horizontalBarPill: Component {
        Row {
            id: hPill

            spacing: Theme.spacingXS

            RecDot {
                anchors.verticalCenter: parent.verticalCenter
            }

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: root.recording ? "stop_circle" : "screenshot_region"
                size: root.iconSize
                color: root.recording ? Theme.error : Theme.surfaceText
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.recording
                text: root.timeText
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.error
            }
        }
    }

    verticalBarPill: Component {
        Column {
            id: vPill

            spacing: Theme.spacingXS

            RecDot {
                anchors.horizontalCenter: parent.horizontalCenter
            }

            DankIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: root.recording ? "stop_circle" : "screenshot_region"
                size: root.iconSize
                color: root.recording ? Theme.error : Theme.surfaceText
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.recording
                text: root.timeText
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.error
            }
        }
    }
}
