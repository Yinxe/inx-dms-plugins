pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

/**
 * Shared tabbed configuration panel (screenshot | recording), reused by the
 * bar-pill popout and the full settings page. The setting controls resolve
 * the enclosing PluginSettings through the parent chain (QmlUtils.findSettings),
 * so this component must be placed inside a PluginSettings root.
 */
Column {
    id: panel

    spacing: Theme.spacingS

    property int tabIndex: 0

    /**
     * Called by the enclosing PluginSettings after it injects pluginService
     * (and on every pluginDataChanged). PluginSettings only iterates its
     * direct content children, so a nested panel must fan the reload out.
     */
    function loadValue() {
        const pages = [shotPage, videoPage];
        for (const page of pages) {
            for (let i = 0; i < page.children.length; i++) {
                const control = page.children[i];
                if (control.loadValue)
                    control.loadValue();
            }
        }
    }

    readonly property var tabs: [
        {
            key: "shot",
            icon: "photo_camera",
            label: I18n.trFor("shotrec", "Screenshot")
        },
        {
            key: "video",
            icon: "videocam",
            label: I18n.trFor("shotrec", "Recording")
        }
    ]

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: tabRow.implicitWidth + Theme.spacingXS * 2
        height: tabRow.implicitHeight + Theme.spacingXS * 2
        radius: height / 2
        color: Theme.surfaceContainerHigh

        Row {
            id: tabRow

            anchors.centerIn: parent
            spacing: Theme.spacingXS

            Repeater {
                model: panel.tabs

                delegate: Rectangle {
                    id: tabChip

                    required property int index
                    required property var modelData

                    readonly property bool active: panel.tabIndex === index

                    width: chipContent.implicitWidth + Theme.spacingM
                    height: chipContent.implicitHeight + Theme.spacingXS
                    radius: height / 2
                    color: active ? Theme.primary : "transparent"

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.shortDuration
                            easing.type: Theme.standardEasing
                        }
                    }

                    Row {
                        id: chipContent

                        anchors.centerIn: parent
                        spacing: Theme.spacingXS

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: tabChip.modelData.icon
                            size: Theme.iconSizeSmall
                            color: tabChip.active ? Theme.onPrimary : Theme.surfaceVariantText
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: tabChip.modelData.label
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: tabChip.active ? Font.DemiBold : Font.Normal
                            color: tabChip.active ? Theme.onPrimary : Theme.surfaceText
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panel.tabIndex = tabChip.index
                    }
                }
            }
        }
    }

    StackLayout {
        id: pages

        width: parent.width
        currentIndex: panel.tabIndex

        // Follow the visible tab so the popout shrinks to fit instead of
        // keeping the tallest tab's blank space.
        implicitHeight: activeItem ? activeItem.implicitHeight : 0
        height: implicitHeight

        Behavior on implicitHeight {
            NumberAnimation {
                duration: Theme.normalDuration
                easing.type: Theme.standardEasing
            }
        }

        // -------------------------------------------------------- screenshot
        Column {
            id: shotPage

            spacing: Theme.spacingS

            StringSetting {
                settingKey: "imageDir"
                label: I18n.trFor("shotrec", "Screenshot folder")
                placeholder: "~/Pictures/Screenshots"
                defaultValue: "~/Pictures/Screenshots"
            }

            SelectionSetting {
                settingKey: "captureDelay"
                label: I18n.trFor("shotrec", "Capture delay")
                defaultValue: "0"
                options: [
                    {
                        label: "0 s",
                        value: "0"
                    },
                    {
                        label: "1 s",
                        value: "1"
                    },
                    {
                        label: "3 s",
                        value: "3"
                    },
                    {
                        label: "5 s",
                        value: "5"
                    },
                    {
                        label: "10 s",
                        value: "10"
                    }
                ]
            }

            ToggleSetting {
                settingKey: "copyToClipboard"
                label: I18n.trFor("shotrec", "Copy screenshots to clipboard")
                defaultValue: true
            }

            ToggleSetting {
                settingKey: "editAfterCapture"
                label: I18n.trFor("shotrec", "Edit after capture")
                defaultValue: true
            }
        }

        // -------------------------------------------------------- recording
        Column {
            id: videoPage

            spacing: Theme.spacingS

            StringSetting {
                settingKey: "videoDir"
                label: I18n.trFor("shotrec", "Recording folder")
                placeholder: "~/Videos"
                defaultValue: "~/Videos"
            }

            SelectionSetting {
                settingKey: "videoFormat"
                label: I18n.trFor("shotrec", "Video format")
                defaultValue: "mp4"
                options: [
                    {
                        label: "MP4",
                        value: "mp4"
                    },
                    {
                        label: "WebM",
                        value: "webm"
                    },
                    {
                        label: "MKV",
                        value: "mkv"
                    }
                ]
            }

            SelectionSetting {
                settingKey: "videoResolution"
                label: I18n.trFor("shotrec", "Resolution")
                defaultValue: "native"
                options: [
                    {
                        label: I18n.trFor("shotrec", "Native"),
                        value: "native"
                    },
                    {
                        label: "1080p",
                        value: "1080p"
                    },
                    {
                        label: "720p",
                        value: "720p"
                    }
                ]
            }

            SelectionSetting {
                settingKey: "videoQuality"
                label: I18n.trFor("shotrec", "Video quality")
                defaultValue: "high"
                options: [
                    {
                        label: I18n.trFor("shotrec", "High"),
                        value: "high"
                    },
                    {
                        label: I18n.trFor("shotrec", "Medium"),
                        value: "medium"
                    },
                    {
                        label: I18n.trFor("shotrec", "Low"),
                        value: "low"
                    }
                ]
            }

            SelectionSetting {
                settingKey: "videoFps"
                label: I18n.trFor("shotrec", "Framerate")
                defaultValue: "30"
                options: [
                    {
                        label: I18n.trFor("shotrec", "Auto"),
                        value: "auto"
                    },
                    {
                        label: "10",
                        value: "10"
                    },
                    {
                        label: "24",
                        value: "24"
                    },
                    {
                        label: "30",
                        value: "30"
                    },
                    {
                        label: "60",
                        value: "60"
                    }
                ]
            }

            SelectionSetting {
                settingKey: "videoAudio"
                label: I18n.trFor("shotrec", "Audio source")
                defaultValue: "off"
                options: [
                    {
                        label: I18n.trFor("shotrec", "Off"),
                        value: "off"
                    },
                    {
                        label: I18n.trFor("shotrec", "System sound"),
                        value: "system"
                    },
                    {
                        label: I18n.trFor("shotrec", "Microphone"),
                        value: "mic"
                    },
                    {
                        label: I18n.trFor("shotrec", "System + microphone"),
                        value: "mixed"
                    }
                ]
            }

            ToggleSetting {
                settingKey: "useHevc"
                label: I18n.trFor("shotrec", "Use HEVC instead of H.264")
                defaultValue: false
            }
        }
    }
}
