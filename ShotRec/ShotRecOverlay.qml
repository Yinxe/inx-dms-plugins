pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets

/**
 * Fullscreen selection overlay drawn on top of the frozen screen grab.
 * Left/Right (or Up/Down) pick a mode, drag selects a region, Enter confirms,
 * Esc cancels.
 */
FocusScope {
    id: root

    // injected by ShotRecDaemon
    property var modes: []
    property int modeIndex: 0
    property string freezePath: ""
    property rect selection: Qt.rect(0, 0, 0, 0)
    property bool hasSelection: false
    property bool isRecordMode: false
    property real pixelScale: 1
    // false while the grab is still running: the surface is mapped but shows
    // nothing, so grim/screencopy never captures the picker UI.
    property bool ready: false

    opacity: root.ready ? 1 : 0

    signal modeStep(int delta)
    signal modePicked(int index)
    signal selectionUpdated(rect rect)
    signal accepted
    signal cancelled

    property bool dragging: false
    property point dragOrigin: Qt.point(0, 0)
    property real dragDistance: 0

    readonly property string activeHint: hasSelection && modes[modeIndex]?.key === "record"
        ? I18n.trFor("shotrec", "Enter to record %1 × %2").arg(Math.round(selection.width * pixelScale)).arg(Math.round(selection.height * pixelScale))
        : hasSelection && modes[modeIndex]?.key === "shot"
        ? I18n.trFor("shotrec", "Enter to capture %1 × %2").arg(Math.round(selection.width * pixelScale)).arg(Math.round(selection.height * pixelScale))
        : String(modes[modeIndex]?.hint || "")

    function clampToScreen(point) {
        return Qt.point(
            Math.max(0, Math.min(width, point.x)),
            Math.max(0, Math.min(height, point.y)));
    }

    function normalizedSelection(from, to) {
        const x = Math.min(from.x, to.x);
        const y = Math.min(from.y, to.y);
        return Qt.rect(x, y, Math.abs(to.x - from.x), Math.abs(to.y - from.y));
    }

    Component.onCompleted: root.forceActiveFocus()

    Keys.onPressed: (event) => {
        if (!root.ready)
            return;
        switch (event.key) {
        case Qt.Key_Left:
        case Qt.Key_Up:
        case Qt.Key_Tab:
            root.modeStep(-1);
            event.accepted = true;
            break;
        case Qt.Key_Right:
        case Qt.Key_Down:
        case Qt.Key_Backtab:
            root.modeStep(1);
            event.accepted = true;
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            root.accepted();
            event.accepted = true;
            break;
        case Qt.Key_Escape:
            root.cancelled();
            event.accepted = true;
            break;
        }
    }

    // ----------------------------------------------------------- frozen frame

    Image {
        id: frozenFrame

        anchors.fill: parent
        source: root.freezePath
        fillMode: Image.Stretch
        asynchronous: true
        cache: false
        smooth: true
        visible: status === Image.Ready
    }

    Rectangle {
        anchors.fill: parent
        color: "#8C000000"
        visible: opacity > 0
    }

    // Selection cut-out: the frozen frame again, offset inside a clipped box,
    // so the chosen area shows its true pixels at screen scale (not a
    // shrunken copy of the whole screen) while everything else stays dimmed.
    Item {
        id: selectionCutout

        visible: root.hasSelection && frozenFrame.status === Image.Ready
        x: root.selection.x
        y: root.selection.y
        width: root.selection.width
        height: root.selection.height
        clip: true

        Image {
            x: -root.selection.x
            y: -root.selection.y
            width: root.width
            height: root.height
            source: root.freezePath
            fillMode: Image.Stretch
            asynchronous: true
            cache: false
            smooth: true
        }
    }

    readonly property var handlePoints: root.hasSelection ? [
        Qt.point(root.selection.x, root.selection.y),
        Qt.point(root.selection.x + root.selection.width, root.selection.y),
        Qt.point(root.selection.x, root.selection.y + root.selection.height),
        Qt.point(root.selection.x + root.selection.width, root.selection.y + root.selection.height)
    ] : []

    // Selection border: theme colour outside plus a white hairline inside so
    // the edge stays readable on dark content.
    Rectangle {
        id: selectionFrame

        visible: root.hasSelection
        color: "transparent"
        border.width: 2
        border.color: Theme.primary
        radius: Theme.spacingXS
        x: root.selection.x
        y: root.selection.y
        width: root.selection.width
        height: root.selection.height

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            color: "transparent"
            border.width: 1
            border.color: "#99FFFFFF"
        }
    }

    Repeater {
        model: root.handlePoints

        Rectangle {
            id: handle

            required property point modelData

            width: Theme.spacingM
            height: Theme.spacingM
            radius: 2
            color: Theme.surfaceContainerHigh
            border.width: 2
            border.color: Theme.primary
            x: modelData.x - width / 2
            y: modelData.y - height / 2
        }
    }

    // Selection size readout
    Rectangle {
        visible: root.hasSelection
        anchors.horizontalCenter: selectionCutout.horizontalCenter
        y: Math.min(root.selection.y + root.selection.height + Theme.spacingS, root.height - height - Theme.spacingM)
        width: sizeLabel.implicitWidth + Theme.spacingM * 2
        height: sizeLabel.implicitHeight + Theme.spacingXS * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        StyledText {
            id: sizeLabel

            anchors.centerIn: parent
            text: `${Math.round(root.selection.width * root.pixelScale)} × ${Math.round(root.selection.height * root.pixelScale)}`
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceText
        }
    }

    // ------------------------------------------------------------ mode picker

    Column {
        id: pickerColumn

        anchors.horizontalCenter: parent.horizontalCenter
        y: Theme.barHeight + Theme.spacingM
        spacing: Theme.spacingS

        // Above dragArea (declared later, so it would otherwise swallow the
        // chip clicks); only the chips themselves accept mouse events.
        z: 2

        // Get out of the way while the user is drawing the rectangle.
        opacity: root.dragging ? 0.15 : 1
        Behavior on opacity {
            NumberAnimation {
                duration: 120
                easing.type: Theme.standardEasing
            }
        }

        Rectangle {
            id: modeBar

            anchors.horizontalCenter: parent.horizontalCenter
            width: modeRow.implicitWidth + Theme.spacingS * 2
            height: modeRow.implicitHeight + Theme.spacingS * 2
            radius: height / 2
            color: Theme.surfaceContainerHigh

            Row {
                id: modeRow

                anchors.centerIn: parent
                spacing: Theme.spacingXS

                Repeater {
                    model: root.modes

                    delegate: Rectangle {
                        id: modeChip

                        required property int index
                        required property var modelData

                        readonly property bool active: root.modeIndex === index

                        width: chipRow.implicitWidth + Theme.spacingM * 2
                        height: chipRow.implicitHeight + Theme.spacingS
                        radius: height / 2
                        color: active ? Theme.primary : "transparent"

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.shortDuration
                                easing.type: Theme.standardEasing
                            }
                        }

                        Row {
                            id: chipRow

                            anchors.centerIn: parent
                            spacing: Theme.spacingXS

                            DankIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: modeChip.modelData.icon
                                size: Theme.iconSizeSmall
                                color: modeChip.active ? Theme.onPrimary : Theme.surfaceVariantText
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modeChip.modelData.label
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: modeChip.active ? Font.DemiBold : Font.Normal
                                color: modeChip.active ? Theme.onPrimary : Theme.surfaceText
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.modePicked(modeChip.index)
                        }
                    }
                }
            }
        }

        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.activeHint
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    // ----------------------------------------------------------------- input

    MouseArea {
        id: dragArea

        anchors.fill: parent
        enabled: root.ready
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.CrossCursor

        onPressed: (mouse) => {
            root.dragOrigin = root.clampToScreen(Qt.point(mouse.x, mouse.y));
            root.dragDistance = 0;
            root.dragging = true;
            root.forceActiveFocus();
        }

        onPositionChanged: (mouse) => {
            if (!root.dragging)
                return;
            const current = root.clampToScreen(Qt.point(mouse.x, mouse.y));
            root.dragDistance = Math.max(root.dragDistance, Math.abs(current.x - root.dragOrigin.x), Math.abs(current.y - root.dragOrigin.y));
            root.selectionUpdated(root.normalizedSelection(root.dragOrigin, current));
        }

        onReleased: {
            root.dragging = false;
            // A click (no drag) clears the region, which falls back to full screen.
            if (root.dragDistance < 4)
                root.selectionUpdated(Qt.rect(0, 0, 0, 0));
        }

        onDoubleClicked: root.accepted()
    }
}
