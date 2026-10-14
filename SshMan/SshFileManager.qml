pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import qs.Common
import qs.Widgets

/**
 * Dual-pane file manager window: local filesystem against the remote side of
 * one ssh config alias, with rsync/scp transfers and progress rows. Lives as
 * a child of the daemon, so it is a real window the plugin owns (ShotRec's
 * PanelWindow is the precedent) and closing it only hides it — transfers
 * keep running against the engine.
 */
DankFloatingWindow {
    id: win

    property var daemon: null
    readonly property string ns: "sshMan"

    property string localPath: Quickshell.env("HOME") || "/"
    /// [{name, isDir}] — reassigned wholesale per repo convention.
    property var localSelected: []
    property var remoteSelected: []

    SshFileEngine {
        id: engine

        daemon: win.daemon
    }

    function tr(text) {
        return I18n.trFor(win.ns, text);
    }

    // Copied from the core FileBrowser (shared logic is copied, not shared).
    function encodeFileUrl(path) {
        if (!path)
            return "";
        return "file://" + path.split("/").map(s => encodeURIComponent(s)).join("/");
    }

    function humanSize(bytes) {
        const value = Number(bytes);
        if (!Number.isFinite(value) || value < 0)
            return "";
        const units = ["B", "KB", "MB", "GB", "TB"];
        let i = 0;
        let n = value;
        while (n >= 1024 && i < units.length - 1) {
            n /= 1024;
            i += 1;
        }
        return (i === 0 ? String(Math.round(n)) : n.toFixed(1)) + " " + units[i];
    }

    function joinPath(dir, name) {
        return dir === "/" ? "/" + name : dir + "/" + name;
    }

    function openHost(host) {
        win.localPath = Quickshell.env("HOME") || "/";
        win.localSelected = [];
        win.remoteSelected = [];
        engine.openFor(host.alias);
        win.visible = true;
    }

    /// Snapshot for the daemon's status IPC — engine state is otherwise only
    /// visible on screen.
    function engineStatus() {
        return {
            host: engine.alias,
            visible: win.visible,
            path: engine.currentPath,
            loading: engine.loading,
            error: engine.loadError,
            entries: engine.entries.length,
            transfers: engine.transfers.map(row => ({
                name: row.name,
                direction: row.direction,
                state: row.state,
                percent: row.percent
            }))
        };
    }

    title: "SSH Files"
    minimumSize: Qt.size(860, 520)
    implicitWidth: 1100
    implicitHeight: 660
    visible: false

    // Selections belong to the listed directory; navigating clears them.
    onLocalPathChanged: win.localSelected = []

    component ToolButton: Rectangle {
        id: tool

        property string iconName: ""
        property string label: ""
        property color accent: Theme.primary

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
            enabled: tool.enabled
            onClicked: tool.tap()
        }
    }

    // One file/folder row. Property names avoid the FolderListModel role
    // names so delegates can declare their required roles without colliding.
    component FileRow: Rectangle {
        id: fileRow

        property string name: ""
        property bool folderMode: false
        property bool symlinkMode: false
        property string sizeText: ""
        property bool selected: false
        property color textColor: Theme.surfaceText

        signal clicked(var mouse)
        signal doubleClicked()

        width: parent ? parent.width : 0
        height: 30
        radius: Theme.cornerRadius
        color: selected ? Theme.surfaceContainerHighest
            : rowMouse.containsMouse ? Theme.surfaceContainerHigh : "transparent"

        DankIcon {
            id: rowIcon
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter
            name: fileRow.folderMode ? "folder" : "insert_drive_file"
            size: Theme.iconSizeSmall
            color: selected ? Theme.primary : Theme.surfaceVariantText
        }

        StyledText {
            id: rowSize
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter
            width: 64
            horizontalAlignment: Text.AlignRight
            text: fileRow.sizeText
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        StyledText {
            anchors.left: rowIcon.right
            anchors.leftMargin: Theme.spacingXS
            anchors.right: rowSize.left
            anchors.rightMargin: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter
            text: fileRow.name + (fileRow.symlinkMode ? " →" : "")
            font.pixelSize: Theme.fontSizeSmall
            color: selected ? Theme.primary : fileRow.textColor
            elide: Text.ElideMiddle
        }

        MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: mouse => fileRow.clicked(mouse)
            onDoubleClicked: fileRow.doubleClicked()
        }
    }

    // ---- Title bar -----------------------------------------------------------

    Item {
        id: titleBar

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 44
        z: 10

        MouseArea {
            anchors.fill: parent
            onPressed: windowControls.tryStartMove()
            onDoubleClicked: windowControls.tryToggleMaximize()
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "folder_open"
                size: Theme.iconSize - 2
                color: Theme.primary
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.trFor(win.ns, "SSH Files")
                    + (engine.alias !== "" ? " · " + engine.alias : "")
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Medium
                color: Theme.surfaceText
                elide: Text.ElideRight
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            DankActionButton {
                visible: windowControls.canMaximize
                circular: false
                iconName: win.maximized ? "fullscreen_exit" : "fullscreen"
                iconSize: Theme.iconSize - 4
                iconColor: Theme.surfaceText
                onClicked: windowControls.tryToggleMaximize()
            }

            DankActionButton {
                circular: false
                iconName: "close"
                iconSize: Theme.iconSize - 4
                iconColor: Theme.surfaceText
                onClicked: win.visible = false
            }
        }
    }

    // ---- Transfers strip (bottom, before panes in declaration order is fine:
    //      the panes anchor to its top) ------------------------------------------

    Column {
        id: transferArea

        visible: engine.transfers.length > 0
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.spacingM
        anchors.rightMargin: Theme.spacingM
        anchors.bottomMargin: Theme.spacingM
        spacing: Theme.spacingXS

        Row {
            width: parent.width
            spacing: Theme.spacingS

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.trFor(win.ns, "Transfers")
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.DemiBold
                color: Theme.surfaceText
            }

            ToolButton {
                anchors.verticalCenter: parent.verticalCenter
                iconName: "close"
                label: I18n.trFor(win.ns, "Clear finished")
                enabled: engine.transfers.some(row =>
                    row.state !== "running" && row.state !== "queued")
                onTap: {
                    engine.transfers.forEach(row => {
                        if (row.state !== "running" && row.state !== "queued")
                            engine.dismiss(row.id);
                    });
                }
            }
        }

        Rectangle {
            width: parent.width
            height: Math.min(transferColumn.implicitHeight, 176) + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh
            clip: true

            DankFlickable {
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                contentHeight: transferColumn.height
                boundsBehavior: Flickable.StopAtBounds
                clip: true

                Column {
                    id: transferColumn
                    width: parent.width
                    spacing: Theme.spacingXS

                    Repeater {
                        model: engine.transfers

                        delegate: Rectangle {
                            id: transferRowItem

                            required property var modelData

                            readonly property var row: modelData
                            readonly property bool active: row.state === "running"
                                || row.state === "queued"

                            width: transferColumn.width
                            height: 28
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHighest

                            DankIcon {
                                id: dirIcon
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                name: row.direction === "up" ? "upload" : "download"
                                size: Theme.iconSizeSmall
                                color: row.state === "failed" ? Theme.error
                                    : row.state === "done" ? Theme.success
                                    : row.state === "cancelled" ? Theme.surfaceVariantText
                                    : Theme.primary
                            }

                            StyledText {
                                id: rowName
                                anchors.left: dirIcon.right
                                anchors.leftMargin: Theme.spacingXS
                                anchors.verticalCenter: parent.verticalCenter
                                width: 200
                                text: row.name
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                elide: Text.ElideMiddle
                            }

                            Rectangle {
                                id: rowBar
                                anchors.left: rowName.right
                                anchors.leftMargin: Theme.spacingXS
                                anchors.verticalCenter: parent.verticalCenter
                                width: 180
                                height: 8
                                radius: 4
                                color: win.surfaceColor

                                Rectangle {
                                    width: transferRowItem.row.percent >= 0
                                        ? Math.min(100, Math.max(0,
                                            transferRowItem.row.percent)) / 100 * parent.width
                                        : parent.width
                                    height: parent.height
                                    radius: parent.radius
                                    color: transferRowItem.row.state === "failed" ? Theme.error
                                        : transferRowItem.row.state === "done" ? Theme.success
                                        : transferRowItem.row.state === "cancelled" ? Theme.surfaceVariantText
                                        : Theme.primary
                                    opacity: transferRowItem.row.percent >= 0 ? 1.0 : 0.25
                                }
                            }

                            ToolButton {
                                id: rowAction
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                iconName: transferRowItem.active ? "close" : "delete"
                                accent: transferRowItem.active ? Theme.error : Theme.primary
                                onTap: {
                                    if (transferRowItem.active)
                                        engine.cancel(transferRowItem.row.id);
                                    else
                                        engine.dismiss(transferRowItem.row.id);
                                }
                            }

                            StyledText {
                                anchors.left: rowBar.right
                                anchors.leftMargin: Theme.spacingXS
                                anchors.right: rowAction.left
                                anchors.rightMargin: Theme.spacingXS
                                anchors.verticalCenter: parent.verticalCenter
                                text: {
                                    const r = transferRowItem.row;
                                    if (r.state === "running")
                                        return r.percent >= 0
                                            ? r.percent + "% · " + r.rate : "…";
                                    if (r.state === "failed")
                                        return r.message;
                                    return I18n.trFor(win.ns, r.state === "done"
                                        ? "Done" : r.state === "cancelled"
                                        ? "Cancelled" : "Queued");
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: transferRowItem.row.state === "failed" ? Theme.error
                                    : Theme.surfaceVariantText
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- Panes ------------------------------------------------------------------

    Item {
        id: mainArea

        anchors.top: titleBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: transferArea.top
        anchors.margins: Theme.spacingM
        anchors.topMargin: Theme.spacingXS

        Row {
            anchors.fill: parent
            spacing: Theme.spacingS

            // -- Local pane
            StyledRect {
                id: localPane

                width: (parent.width - actionsCol.implicitWidth - Theme.spacingS * 2) / 2
                height: parent.height
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh

                Row {
                    id: localPathBar

                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: Theme.spacingS
                    spacing: Theme.spacingXS

                    ToolButton {
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: "home"
                        onTap: win.localPath = Quickshell.env("HOME") || "/"
                    }

                    ToolButton {
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: "arrow_upward"
                        enabled: win.localPath !== "/"
                        onTap: {
                            const cut = win.localPath.lastIndexOf("/");
                            win.localPath = cut <= 0 ? "/" : win.localPath.substring(0, cut);
                        }
                    }

                    DankTextField {
                        id: localPathField

                        width: parent.width - (28 * 2 + Theme.spacingXS * 2)
                        anchors.verticalCenter: parent.verticalCenter
                        placeholderText: I18n.trFor(win.ns, "Local path")
                        text: win.localPath
                        onTextChanged: {
                            // Re-sync when navigation changes the path, unless
                            // the user is mid-typing.
                            if (!activeFocus)
                                text = win.localPath;
                        }
                        onEditingFinished: {
                            const value = text.trim().replace(/\/+$/, "");
                            if (value.startsWith("/"))
                                win.localPath = value === "" ? "/" : value;
                            else
                                text = win.localPath;
                        }
                    }
                }

                StyledText {
                    id: localHeader

                    anchors.top: localPathBar.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: Theme.spacingS
                    text: I18n.trFor(win.ns, "Local")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                FolderListModel {
                    id: folderModel

                    showDirsFirst: true
                    showHidden: false
                    folder: win.encodeFileUrl(win.localPath)
                    sortField: FolderListModel.Name
                }

                DankListView {
                    anchors.top: localHeader.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: Theme.spacingS
                    anchors.topMargin: 0
                    visible: folderModel.count > 0
                    model: folderModel
                    clip: true

                    delegate: FileRow {
                        required property string fileName
                        required property bool fileIsDir
                        required property var fileSize

                        name: fileName
                        folderMode: fileIsDir
                        sizeText: fileIsDir ? "" : win.humanSize(fileSize)
                        selected: win.localSelected.some(e => e.name === fileName)

                        onClicked: mouse => {
                            if (mouse.modifiers & Qt.ControlModifier) {
                                win.localSelected = selected
                                    ? win.localSelected.filter(e => e.name !== fileName)
                                    : win.localSelected.concat([{
                                        name: fileName,
                                        isDir: fileIsDir
                                    }]);
                            } else {
                                win.localSelected = [{
                                    name: fileName,
                                    isDir: fileIsDir
                                }];
                            }
                        }
                        onDoubleClicked: {
                            if (fileIsDir)
                                win.localPath = win.joinPath(win.localPath, fileName);
                        }
                    }
                }

                StyledText {
                    anchors.centerIn: parent
                    visible: folderModel.count === 0
                    text: I18n.trFor(win.ns, "Empty folder")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }

            // -- Actions
            Column {
                id: actionsCol
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS

                ToolButton {
                    iconName: "upload"
                    label: I18n.trFor(win.ns, "Upload")
                    enabled: engine.currentPath !== "" && !engine.loading
                        && engine.loadError === "" && win.localSelected.length > 0
                    onTap: engine.startUpload(win.localPath, win.localSelected)
                }

                ToolButton {
                    iconName: "download"
                    label: I18n.trFor(win.ns, "Download")
                    enabled: engine.currentPath !== "" && !engine.loading
                        && engine.loadError === "" && win.remoteSelected.length > 0
                    onTap: engine.startDownload(win.localPath, win.remoteSelected)
                }
            }

            // -- Remote pane
            StyledRect {
                id: remotePane

                width: localPane.width
                height: parent.height
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh

                Row {
                    id: remotePathBar

                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: Theme.spacingS
                    spacing: Theme.spacingXS

                    ToolButton {
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: "home"
                        enabled: engine.homePath !== ""
                        onTap: engine.listDir(engine.homePath)
                    }

                    ToolButton {
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: "arrow_upward"
                        enabled: engine.currentPath !== "/" && engine.currentPath !== ""
                        onTap: engine.listDir(engine.parentOf(engine.currentPath))
                    }

                    ToolButton {
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: "refresh"
                        enabled: engine.alias !== "" && !engine.loading
                        onTap: {
                            if (engine.currentPath !== "")
                                engine.listDir(engine.currentPath);
                            else
                                engine.openFor(engine.alias);
                        }
                    }

                    DankTextField {
                        id: remotePathField

                        width: parent.width - (28 * 3 + Theme.spacingXS * 3)
                        anchors.verticalCenter: parent.verticalCenter
                        placeholderText: I18n.trFor(win.ns, "Remote path")
                        text: engine.currentPath
                        onTextChanged: {
                            if (!activeFocus)
                                text = engine.currentPath;
                        }
                        onEditingFinished: {
                            const value = text.trim().replace(/\/+$/, "");
                            if (value.startsWith("/") && engine.alias !== "")
                                engine.listDir(value === "" ? "/" : value);
                            else
                                text = engine.currentPath;
                        }
                    }
                }

                StyledText {
                    id: remoteHeader

                    anchors.top: remotePathBar.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: Theme.spacingS
                    text: {
                        if (engine.loading)
                            return I18n.trFor(win.ns, "Loading…");
                        if (engine.loadError !== "")
                            return "";
                        return I18n.trFor(win.ns, "Remote") + (engine.badNames > 0
                            ? " · " + I18n.trFor(win.ns,
                                "Hidden entries with unsupported names: %1").arg(engine.badNames)
                            : "");
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                }

                Column {
                    id: remoteError

                    visible: engine.loadError !== "" && !engine.loading
                    anchors.top: remoteHeader.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: Theme.spacingS
                    anchors.topMargin: 0
                    spacing: Theme.spacingS

                    StyledText {
                        width: parent.width
                        text: engine.loadErrorMessage
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.error
                        wrapMode: Text.WordWrap
                    }

                    StyledText {
                        visible: engine.loadError === "auth"
                        width: parent.width
                        text: I18n.trFor(win.ns,
                            "File browsing needs key authentication; terminal connections still work with passwords.")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                }

                DankListView {
                    anchors.top: remoteHeader.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: Theme.spacingS
                    anchors.topMargin: 0
                    visible: engine.loadError === "" || engine.loading
                    opacity: engine.loading ? 0.4 : 1.0
                    model: engine.entries
                    clip: true

                    delegate: FileRow {
                        required property var modelData

                        name: modelData.name
                        folderMode: modelData.isDir
                        symlinkMode: modelData.isSymlink
                        sizeText: modelData.isDir ? "" : win.humanSize(modelData.size)
                        selected: win.remoteSelected.some(e => e.name === modelData.name)

                        onClicked: mouse => {
                            if (mouse.modifiers & Qt.ControlModifier) {
                                win.remoteSelected = selected
                                    ? win.remoteSelected.filter(e => e.name !== modelData.name)
                                    : win.remoteSelected.concat([{
                                        name: modelData.name,
                                        isDir: modelData.isDir
                                    }]);
                            } else {
                                win.remoteSelected = [{
                                    name: modelData.name,
                                    isDir: modelData.isDir
                                }];
                            }
                        }
                        onDoubleClicked: {
                            if (modelData.isDir)
                                engine.listDir(modelData.path);
                        }
                    }
                }

                StyledText {
                    anchors.centerIn: parent
                    visible: engine.entries.length === 0 && engine.loadError === ""
                        && !engine.loading
                    text: I18n.trFor(win.ns, "Empty folder")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }
        }
    }

    FloatingWindowControls {
        id: windowControls
        targetWindow: win
    }
}
