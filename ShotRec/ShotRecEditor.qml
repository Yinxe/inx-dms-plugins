pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

/**
 * Standalone post-capture editor: pen / rectangle / arrow / text / mosaic
 * annotations plus a re-crop over the captured PNG. Enter saves, Esc discards.
 *
 * Coordinate model: every shape is stored normalised to the FULL source image
 * (0..1 over sourceSize), so a re-crop never displaces existing annotations.
 * `crop` is the current view rectangle in that same space. The shot Image is
 * never itself clipped (so mosaic drawImage keeps sampling the true source
 * pixels); instead a clipping container shows only the view, which makes
 * re-cropping visibly re-base the picture. The grabbed annotation layer
 * therefore always covers exactly the crop region, which is what the daemon's
 * crop+overlay composite expects.
 *
 * Editing itself touches no external tool: the daemon composites the grabbed
 * alpha layer onto the source with a single ffmpeg call on save.
 */
DankFloatingWindow {
    id: win

    property string cacheDir: ""

    signal accepted(string annPath, string cropGeom, int outWidth, int outHeight)
    signal cancelled()

    visible: false
    title: I18n.trFor("shotrec", "Edit screenshot")

    readonly property var tools: [
        {
            key: "pen",
            icon: "draw",
            label: I18n.trFor("shotrec", "Pen")
        },
        {
            key: "rect",
            icon: "rectangle",
            label: I18n.trFor("shotrec", "Rectangle")
        },
        {
            key: "arrow",
            icon: "north_east",
            label: I18n.trFor("shotrec", "Arrow")
        },
        {
            key: "text",
            icon: "text_format",
            label: I18n.trFor("shotrec", "Text")
        },
        {
            key: "mosaic",
            icon: "pixelate",
            label: I18n.trFor("shotrec", "Mosaic")
        },
        {
            key: "crop",
            icon: "crop",
            label: I18n.trFor("shotrec", "Crop")
        }
    ]
    readonly property var palette: ["#F4433C", "#FF9800", "#FFEB3B", "#4CAF50", "#2196F3", "#FFFFFF", "#101010"]
    // Fractions of the full source width: lineScales is the stroke weight for
    // pen/rect/arrow, mosaicScales is the mosaic block size.
    readonly property var lineScales: [0.004, 0.008, 0.014]
    readonly property var mosaicScales: [0.03, 0.05, 0.08]

    property int toolIndex: 0
    property int colorIndex: 0
    property int widthIndex: 1
    readonly property string tool: tools[toolIndex].key

    property string sourcePath: ""
    property string pendingCrop: ""
    property var shapes: []
    property var draft: null
    // Current view rectangle, normalised to the full source (0,0,1,1 = whole).
    property rect crop: Qt.rect(0, 0, 1, 1)
    // Live crop selection while dragging the crop tool (full-source space).
    property rect cropDraft: Qt.rect(0, 0, 0, 0)
    property bool cropping: false

    readonly property bool edited: shapes.length > 0
    readonly property bool cropped: crop.width < 0.995 || crop.height < 0.995 || crop.x > 0.005 || crop.y > 0.005

    // Pending text annotation (the input card is open).
    property bool textEditing: false
    property real textNx: 0
    property real textNy: 0

    function tr(text) {
        return I18n.trFor("shotrec", text);
    }

    function fileUrl(path) {
        return "file://" + path.split("/").map(s => encodeURIComponent(s)).join("/");
    }

    /** geometry is an optional initial crop in PHYSICAL pixels "x,y WxH", or "". */
    function open(path, geometry) {
        win.sourcePath = path;
        win.pendingCrop = geometry;
        win.shapes = [];
        win.draft = null;
        win.crop = Qt.rect(0, 0, 1, 1);
        win.cropDraft = Qt.rect(0, 0, 0, 0);
        win.cropping = false;
        win.textEditing = false;
        win.toolIndex = 0;
        win.visible = true;
        Qt.callLater(() => focusArea.forceActiveFocus());
    }

    function cancelEdit() {
        win.visible = false;
        win.cancelled();
    }

    function parseCrop(geom) {
        if (!geom)
            return Qt.rect(0, 0, 1, 1);
        const [origin, size] = geom.split(" ");
        const [x, y] = origin.split(",");
        const [w, h] = size.split("x");
        const sw = shot.sourceSize.width;
        const sh = shot.sourceSize.height;
        if (!sw || !sh)
            return Qt.rect(0, 0, 1, 1);
        return Qt.rect(Number(x) / sw, Number(y) / sh, Number(w) / sw, Number(h) / sh);
    }

    function afterLoad() {
        win.crop = parseCrop(win.pendingCrop);
        win.pendingCrop = "";
        // Size the window to the initial full frame; the toolbar must never
        // clip, so widen for the widest of the two lines.
        const aspect = shot.sourceSize.width / shot.sourceSize.height;
        const availW = layout.Screen.width * 0.85;
        const availH = layout.Screen.height * 0.72;
        const dw = Math.max(320, Math.min(availW, availH * aspect));
        const chrome = Theme.spacingM * 2 + Theme.spacingXL;
        win.implicitWidth = Math.max(dw + Theme.spacingM * 2, toolLine.implicitWidth + chrome, actionLine.implicitWidth + chrome);
        win.implicitHeight = dw / aspect + toolbarBg.height + Theme.spacingS * 2;
    }

    // Output size in PHYSICAL pixels after the crop (before, if no crop).
    readonly property int outWidth: Math.round(shot.sourceSize.width * (cropped ? crop.width : 1))
    readonly property int outHeight: Math.round(shot.sourceSize.height * (cropped ? crop.height : 1))

    function cropGeometry() {
        if (!win.cropped)
            return "";
        const sw = shot.sourceSize.width;
        const sh = shot.sourceSize.height;
        const x = Math.round(win.crop.x * sw);
        const y = Math.round(win.crop.y * sh);
        const w = Math.min(Math.round(win.crop.width * sw), sw - x);
        const h = Math.min(Math.round(win.crop.height * sh), sh - y);
        if (w < 2 || h < 2)
            return "";
        return `${x},${y} ${w}x${h}`;
    }

    function saveEdit() {
        if (shot.status !== Image.Ready)
            return;
        if (win.textEditing)
            win.commitText();
        if (!win.edited) {
            // Hide first: the daemon moves/consumes sourcePath from here on.
            win.visible = false;
            win.accepted("", cropGeometry(), win.outWidth, win.outHeight);
            return;
        }
        const tmp = `${win.cacheDir}/edit-ann-${Date.now()}.png`;
        annCanvas.grabToImage((result) => {
            if (result.saveToFile(tmp)) {
                win.visible = false;
                win.accepted(tmp, cropGeometry(), win.outWidth, win.outHeight);
            } else {
                ToastService.showError(win.tr("Could not write the screenshot"));
            }
        });
    }

    function pushShape(s) {
        win.shapes = win.shapes.concat([s]);
        annCanvas.requestPaint();
    }

    function undo() {
        if (!win.shapes.length)
            return;
        win.shapes = win.shapes.slice(0, -1);
        annCanvas.requestPaint();
    }

    function clearShapes() {
        win.shapes = [];
        annCanvas.requestPaint();
    }

    /**
     * Apply a re-crop: the new view becomes the whole frame, so every shape is
     * remapped from old-view space into the new (smaller) source region.
     */
    function applyCrop(r) {
        const nx = Math.max(win.crop.x, r.x);
        const ny = Math.max(win.crop.y, r.y);
        const nr = Math.min(win.crop.x + win.crop.width, r.x + r.width);
        const nb = Math.min(win.crop.y + win.crop.height, r.y + r.height);
        const w = nr - nx;
        const h = nb - ny;
        if (w < 0.02 || h < 0.02)
            return;
        const map = (v, o, s) => (v - o) / s;
        const out = [];
        for (const s of win.shapes) {
            const c = Object.assign({}, s);
            if (c.points)
                c.points = c.points.map(p => Qt.point(map(p.x, nx, w), map(p.y, ny, h)));
            if (c.x !== undefined)
                c.x = map(c.x, nx, w);
            if (c.y !== undefined)
                c.y = map(c.y, ny, h);
            if (c.w !== undefined)
                c.w = c.w / w;
            if (c.h !== undefined)
                c.h = c.h / h;
            if (c.x1 !== undefined) {
                c.x1 = map(c.x1, nx, w);
                c.y1 = map(c.y1, ny, h);
                c.x2 = map(c.x2, nx, w);
                c.y2 = map(c.y2, ny, h);
            }
            if (c.lw)
                c.lw = c.lw / w;
            if (c.blk)
                c.blk = c.blk / w;
            if (c.fs)
                c.fs = c.fs / w;
            out.push(c);
        }
        win.shapes = out;
        win.crop = Qt.rect(nx, ny, w, h);
        annCanvas.requestPaint();
    }

    // -------------------------------------------------------------- text tool

    function beginText(nx, ny) {
        if (win.textEditing)
            win.commitText();
        win.textNx = nx;
        win.textNy = ny;
        textInput.text = "";
        win.textEditing = true;
        // The card is only visible from this frame on: an item that was
        // hidden cannot take active focus until it is in the chain.
        Qt.callLater(() => textInput.forceActiveFocus());
    }

    function commitText() {
        const t = textInput.text.trim();
        if (t) {
            // Store the font size normalised to the full source width.
            const fs = textInput.font.pixelSize / shot.width * win.crop.width;
            win.pushShape({
                type: "text",
                color: win.palette[win.colorIndex],
                lw: 0,
                fs: fs,
                text: t,
                x: win.textNx,
                y: win.textNy
            });
        }
        win.textEditing = false;
    }

    // ------------------------------------------------------------- test hooks

    /** Automation/test hook: pushes a diagonal arrow in the upper-left area. */
    function addTestArrow() {
        win.pushShape({
            type: "arrow",
            color: "#F4433C",
            lw: win.lineScales[1],
            x1: 0.1,
            y1: 0.1,
            x2: 0.4,
            y2: 0.4
        });
    }

    /** Automation/test hook: pushes a mosaic rectangle over the upper-left. */
    function addTestMosaic() {
        win.pushShape({
            type: "mosaic",
            blk: win.mosaicScales[1],
            x: 0.08,
            y: 0.08,
            w: 0.3,
            h: 0.3
        });
    }

    // ---------------------------------------------------------------- keys

    onVisibleChanged: {
        if (visible)
            Qt.callLater(() => focusArea.forceActiveFocus());
    }

    // ---------------------------------------------------------------- paint

    // Full-source normalised coordinate -> display pixel (view space).
    readonly property real vx: crop.x
    readonly property real vy: crop.y
    readonly property real vw: crop.width > 0 ? crop.width : 1
    readonly property real vh: crop.height > 0 ? crop.height : 1

    function drawShape(ctx, s) {
        const W = annCanvas.width;
        const H = annCanvas.height;
        const X = (nx) => (nx - win.vx) / win.vw * W;
        const Y = (ny) => (ny - win.vy) / win.vh * H;
        const SX = (f) => f / win.vw * W;
        const SY = (f) => f / win.vh * H;
        const lw = Math.max(1, SX(s.lw));
        ctx.strokeStyle = s.color;
        ctx.fillStyle = s.color;
        ctx.lineWidth = lw;
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
        if (s.type === "pen") {
            if (s.points.length === 1) {
                ctx.beginPath();
                ctx.arc(X(s.points[0].x), Y(s.points[0].y), lw / 2, 0, 2 * Math.PI);
                ctx.fill();
            } else {
                ctx.beginPath();
                ctx.moveTo(X(s.points[0].x), Y(s.points[0].y));
                for (let i = 1; i < s.points.length; i++)
                    ctx.lineTo(X(s.points[i].x), Y(s.points[i].y));
                ctx.stroke();
            }
        } else if (s.type === "rect") {
            ctx.strokeRect(X(s.x), Y(s.y), SX(s.w), SY(s.h));
        } else if (s.type === "arrow") {
            const x1 = X(s.x1);
            const y1 = Y(s.y1);
            const x2 = X(s.x2);
            const y2 = Y(s.y2);
            const ang = Math.atan2(y2 - y1, x2 - x1);
            const hl = Math.max(8, lw * 3.2);
            ctx.beginPath();
            ctx.moveTo(x1, y1);
            ctx.lineTo(x2, y2);
            ctx.moveTo(x2, y2);
            ctx.lineTo(x2 - hl * Math.cos(ang - 0.5), y2 - hl * Math.sin(ang - 0.5));
            ctx.moveTo(x2, y2);
            ctx.lineTo(x2 - hl * Math.cos(ang + 0.5), y2 - hl * Math.sin(ang + 0.5));
            ctx.stroke();
        } else if (s.type === "text") {
            ctx.font = `${Math.max(8, SX(s.fs))}px sans-serif`;
            ctx.textBaseline = "top";
            ctx.fillText(s.text, X(s.x), Y(s.y));
        } else if (s.type === "mosaic") {
            // Fill the rectangle with flat mosaic blocks: each block samples a
            // single full-source pixel (nearest neighbour), so the preview is
            // the real pixels and the grab carries them into the output.
            const blk = s.blk;
            const sw = shot.sourceSize.width;
            const sh = shot.sourceSize.height;
            const x0 = s.x;
            const y0 = s.y;
            const x1 = s.x + s.w;
            const y1 = s.y + s.h;
            ctx.imageSmoothingEnabled = false;
            for (let gy = y0; gy < y1; gy += blk) {
                const ch = Math.min(blk, y1 - gy);
                for (let gx = x0; gx < x1; gx += blk) {
                    const cw = Math.min(blk, x1 - gx);
                    let sx = Math.round((gx + cw / 2) * sw);
                    let sy = Math.round((gy + ch / 2) * sh);
                    sx = Math.max(0, Math.min(sx, sw - 1));
                    sy = Math.max(0, Math.min(sy, sh - 1));
                    ctx.drawImage(shot, sx, sy, 1, 1, X(gx), Y(gy), SX(cw), SY(ch));
                }
            }
            ctx.imageSmoothingEnabled = true;
            // Border so the covered region stays legible.
            ctx.strokeStyle = "#FFFFFFFF";
            ctx.lineWidth = Math.max(1, SX(0.004));
            ctx.strokeRect(X(x0), Y(y0), SX(s.w), SY(s.h));
        }
    }

    // ---------------------------------------------------------------- layout

    FocusScope {
        id: focusArea

        anchors.fill: parent

        Keys.onPressed: (event) => {
            if (win.textEditing)
                return;
            const ctrl = event.modifiers & (Qt.ControlModifier | Qt.MetaModifier);
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                win.saveEdit();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                if (win.cropping) {
                    win.cropping = false;
                    annCanvas.requestPaint();
                } else {
                    win.cancelEdit();
                }
                event.accepted = true;
            } else if (ctrl && event.key === Qt.Key_Z) {
                win.undo();
                event.accepted = true;
            } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_6) {
                win.toolIndex = event.key - Qt.Key_1;
                event.accepted = true;
            }
        }

        Item {
            id: layout

            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
                bottom: toolbarBg.top
                margins: Theme.spacingM
            }

            // Clipping container sized to the current view's aspect.
            Item {
                id: viewPort

                anchors.centerIn: parent
                readonly property real srcAspect: shot.sourceSize.width > 0 && shot.sourceSize.height > 0 ? shot.sourceSize.width / shot.sourceSize.height : 1
                readonly property real viewAspect: srcAspect * win.crop.width / win.crop.height
                width: shot.status === Image.Ready ? Math.min(parent.width, parent.height * viewAspect) : 0
                height: shot.status === Image.Ready ? width / viewAspect : 0
                clip: true

                Image {
                    id: shot

                    // Full source, scaled to the view and offset so the crop
                    // region fills the (clipping) container.
                    width: viewPort.width / (win.crop.width > 0 ? win.crop.width : 1)
                    height: viewPort.height / (win.crop.height > 0 ? win.crop.height : 1)
                    x: -win.crop.x * width
                    y: -win.crop.y * height
                    source: win.sourcePath ? win.fileUrl(win.sourcePath) : ""
                    fillMode: Image.Stretch
                    asynchronous: true
                    cache: false
                    smooth: true

                    onStatusChanged: {
                        if (status === Image.Ready)
                            win.afterLoad();
                    }
                }

                Canvas {
                    id: annCanvas

                    anchors.fill: parent

                    onPaint: {
                        const ctx = getContext("2d");
                        ctx.reset();
                        for (const s of win.shapes)
                            win.drawShape(ctx, s);
                        if (win.draft)
                            win.drawShape(ctx, win.draft);
                        // Live crop selection border.
                        if (win.cropping) {
                            const W = width;
                            const H = height;
                            const X = (nx) => (nx - win.vx) / win.vw * W;
                            const Y = (ny) => (ny - win.vy) / win.vh * H;
                            ctx.strokeStyle = Theme.primary;
                            ctx.lineWidth = 2;
                            ctx.setLineDash([6, 4]);
                            ctx.strokeRect(X(win.cropDraft.x), Y(win.cropDraft.y), win.cropDraft.width / win.vw * W, win.cropDraft.height / win.vh * H);
                            ctx.setLineDash([]);
                        }
                    }
                }

                MouseArea {
                    id: pad

                    anchors.fill: parent
                    enabled: shot.status === Image.Ready
                    acceptedButtons: Qt.LeftButton
                    cursorShape: Qt.CrossCursor

                    property point origin

                    // Display pixel -> full-source normalised coordinate.
                    function norm(event) {
                        const fx = Math.max(0, Math.min(1, event.x / viewPort.width));
                        const fy = Math.max(0, Math.min(1, event.y / viewPort.height));
                        return Qt.point(win.crop.x + fx * win.crop.width, win.crop.y + fy * win.crop.height);
                    }

                    function normRect(a, b) {
                        return Qt.rect(Math.min(a.x, b.x), Math.min(a.y, b.y), Math.abs(b.x - a.x), Math.abs(b.y - a.y));
                    }

                    onPressed: (event) => {
                        focusArea.forceActiveFocus();
                        const p = norm(event);
                        pad.origin = p;
                        if (win.tool === "text") {
                            win.beginText(p.x, p.y);
                            return;
                        }
                        if (win.tool === "crop") {
                            win.cropping = true;
                            win.cropDraft = Qt.rect(p.x, p.y, 0, 0);
                            annCanvas.requestPaint();
                            return;
                        }
                        if (win.tool === "pen") {
                            win.draft = {
                                type: "pen",
                                color: win.palette[win.colorIndex],
                                lw: win.lineScales[win.widthIndex],
                                points: [p]
                            };
                            annCanvas.requestPaint();
                        } else if (win.tool === "rect") {
                            win.draft = {
                                type: "rect",
                                color: win.palette[win.colorIndex],
                                lw: win.lineScales[win.widthIndex],
                                x: p.x,
                                y: p.y,
                                w: 0,
                                h: 0
                            };
                            annCanvas.requestPaint();
                        } else if (win.tool === "mosaic") {
                            win.draft = {
                                type: "mosaic",
                                blk: win.mosaicScales[win.widthIndex],
                                x: p.x,
                                y: p.y,
                                w: 0,
                                h: 0
                            };
                            annCanvas.requestPaint();
                        } else if (win.tool === "arrow") {
                            win.draft = {
                                type: "arrow",
                                color: win.palette[win.colorIndex],
                                lw: win.lineScales[win.widthIndex],
                                x1: p.x,
                                y1: p.y,
                                x2: p.x,
                                y2: p.y
                            };
                            annCanvas.requestPaint();
                        }
                    }

                    onPositionChanged: (event) => {
                        if (!pad.pressed)
                            return;
                        const p = norm(event);
                        const d = win.draft;
                        if (win.tool === "pen" && d) {
                            d.points.push(p);
                        } else if (win.tool === "crop" && win.cropping) {
                            win.cropDraft = normRect(origin, p);
                        } else if (d) {
                            const r = normRect(origin, p);
                            if (win.tool === "rect" || win.tool === "mosaic") {
                                d.x = r.x;
                                d.y = r.y;
                                d.w = r.width;
                                d.h = r.height;
                            } else if (win.tool === "arrow") {
                                d.x2 = p.x;
                                d.y2 = p.y;
                            }
                        } else {
                            return;
                        }
                        annCanvas.requestPaint();
                    }

                    onReleased: {
                        const d = win.draft;
                        if (win.tool === "pen") {
                            if (d && d.points.length)
                                win.pushShape(d);
                        } else if (win.tool === "rect" || win.tool === "mosaic") {
                            if (d && Math.max(d.w, d.h) > 0.008)
                                win.pushShape(d);
                        } else if (win.tool === "arrow") {
                            if (d && Math.hypot(d.x2 - d.x1, d.y2 - d.y1) > 0.008)
                                win.pushShape(d);
                        } else if (win.tool === "crop" && win.cropping) {
                            if (win.cropDraft.width > 0.02 && win.cropDraft.height > 0.02)
                                win.applyCrop(win.cropDraft);
                            win.cropping = false;
                            win.cropDraft = Qt.rect(0, 0, 0, 0);
                        }
                        win.draft = null;
                        annCanvas.requestPaint();
                    }
                }

                // Text annotation card: lives above the canvas, commits on
                // Enter/focus-out, aborts on Esc.
                Rectangle {
                    id: textCard

                    visible: win.textEditing
                    z: 10
                    x: Math.min((win.textNx - win.crop.x) / win.crop.width * viewPort.width, Math.max(0, viewPort.width - width))
                    y: Math.min((win.textNy - win.crop.y) / win.crop.height * viewPort.height, Math.max(0, viewPort.height - height))
                    width: Math.max(64, textInput.implicitWidth + Theme.spacingS)
                    height: textInput.font.pixelSize * 1.7
                    radius: Theme.spacingXS / 2
                    color: "#CC1E1E1E"
                    border.width: 1
                    border.color: Theme.primary

                    TextInput {
                        id: textInput

                        anchors {
                            fill: parent
                            margins: Theme.spacingXXS * 2
                        }
                        color: win.palette[win.colorIndex]
                        font.pixelSize: Math.max(12, Math.round(viewPort.width * (0.02 + win.widthIndex * 0.012)))
                        selectionColor: Theme.primary
                        selectByMouse: true
                        clip: true

                        onActiveFocusChanged: {
                            if (!activeFocus && win.textEditing)
                                win.commitText();
                        }
                        onAccepted: win.commitText()
                    }
                }
            }
        }

        // ------------------------------------------------------------- toolbar

        Rectangle {
            id: toolbarBg

            anchors {
                bottom: parent.bottom
                left: parent.left
                right: parent.right
            }
            implicitHeight: toolbarCol.implicitHeight + Theme.spacingM
            height: implicitHeight
            color: Theme.surfaceContainerHigh

            Column {
                id: toolbarCol

                anchors.centerIn: parent
                spacing: Theme.spacingS

                // Line 1: tools | colours | stroke width.
                Row {
                    id: toolLine

                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Theme.spacingS

                    component GroupPill: Rectangle {
                        id: pill

                        default property alias pillContent: pillRow.data
                        property real pillPadding: Theme.spacingS

                        width: pillRow.implicitWidth + pillPadding * 2
                        height: pillRow.implicitHeight + pillPadding
                        radius: height / 2
                        color: Theme.surfaceContainer

                        Row {
                            id: pillRow

                            anchors.centerIn: parent
                            spacing: Theme.spacingXS
                        }
                    }

                    GroupPill {
                        Repeater {
                            model: win.tools

                            delegate: Rectangle {
                                id: toolChip

                                required property int index
                                required property var modelData

                                readonly property bool active: win.toolIndex === index

                                width: chipRow.implicitWidth + Theme.spacingS
                                height: chipRow.implicitHeight + Theme.spacingXS
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
                                    spacing: Theme.spacingXXS * 2

                                    DankIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: toolChip.modelData.icon
                                        size: Theme.iconSizeSmall
                                        color: toolChip.active ? Theme.onPrimary : Theme.surfaceVariantText
                                    }

                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: toolChip.modelData.label
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: toolChip.active ? Font.DemiBold : Font.Normal
                                        color: toolChip.active ? Theme.onPrimary : Theme.surfaceText
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        win.toolIndex = toolChip.index;
                                        focusArea.forceActiveFocus();
                                    }
                                }
                            }
                        }
                    }

                    GroupPill {
                        Repeater {
                            model: win.palette

                            delegate: Rectangle {
                                id: dot

                                required property int index
                                required property var modelData

                                readonly property bool active: win.colorIndex === index

                                width: Theme.spacingL
                                height: Theme.spacingL
                                radius: Theme.spacingL / 2
                                anchors.verticalCenter: parent.verticalCenter
                                color: dot.modelData
                                border.width: 2
                                border.color: active ? Theme.onPrimary : "#33FFFFFF"

                                Rectangle {
                                    visible: dot.active
                                    anchors.centerIn: parent
                                    width: dot.width * 0.45
                                    height: width
                                    radius: height / 2
                                    color: dot.modelData
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: win.colorIndex = index
                                }
                            }
                        }
                    }

                    GroupPill {
                        Repeater {
                            model: win.lineScales

                            delegate: Rectangle {
                                id: wbtn

                                required property int index
                                required property var modelData

                                readonly property bool active: win.widthIndex === index

                                width: Theme.spacingXL
                                height: Theme.spacingL * 1.6
                                radius: Theme.spacingXS
                                color: active ? Theme.surfaceVariant : "transparent"

                                Rectangle {
                                    anchors.centerIn: parent
                                    width: parent.width - Theme.spacingS
                                    height: Math.max(2, Math.round(modelData * 500))
                                    radius: height / 2
                                    color: active ? Theme.primary : Theme.surfaceVariantText
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: win.widthIndex = index
                                }
                            }
                        }
                    }
                }

                // Line 2: actions, each button carrying its own shortcut so the
                // hint is never repeated as a separate label.
                Row {
                    id: actionLine

                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Theme.spacingXS

                    Repeater {
                        model: [
                            {
                                key: "undo",
                                icon: "undo",
                                label: I18n.trFor("shotrec", "Undo"),
                                sc: "Ctrl+Z",
                                primary: false
                            },
                            {
                                key: "clear",
                                icon: "delete_sweep",
                                label: I18n.trFor("shotrec", "Clear"),
                                sc: "",
                                primary: false
                            },
                            {
                                key: "cancel",
                                icon: "close",
                                label: I18n.trFor("shotrec", "Cancel"),
                                sc: "Esc",
                                primary: false
                            },
                            {
                                key: "save",
                                icon: "check",
                                label: I18n.trFor("shotrec", "Save"),
                                sc: "Enter",
                                primary: true
                            }
                        ]

                        delegate: Rectangle {
                            id: act

                            required property var modelData

                            readonly property bool primary: modelData.primary

                            width: actRow.implicitWidth + (primary ? Theme.spacingM : Theme.spacingS)
                            height: actRow.implicitHeight + (primary ? Theme.spacingS : Theme.spacingXS)
                            radius: height / 2
                            color: primary ? Theme.primary : "transparent"

                            Row {
                                id: actRow

                                anchors.centerIn: parent
                                spacing: Theme.spacingXXS * 2

                                DankIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: act.modelData.icon
                                    size: Theme.iconSizeSmall
                                    color: act.primary ? Theme.onPrimary : Theme.surfaceVariantText
                                }

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: act.modelData.label
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: act.primary ? Font.DemiBold : Font.Normal
                                    color: act.primary ? Theme.onPrimary : Theme.surfaceText
                                }

                                StyledText {
                                    visible: act.modelData.sc.length > 0
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: act.modelData.sc
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: act.primary ? "#B3FFFFFF" : Theme.surfaceVariantText
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const k = act.modelData.key;
                                    if (k === "undo") {
                                        win.undo();
                                        focusArea.forceActiveFocus();
                                    } else if (k === "clear") {
                                        win.clearShapes();
                                        focusArea.forceActiveFocus();
                                    } else if (k === "cancel") {
                                        win.cancelEdit();
                                    } else {
                                        win.saveEdit();
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
