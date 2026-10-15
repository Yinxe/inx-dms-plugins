pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Modules.Plugins
import qs.Services

/**
 * Shot & Rec - GNOME-style unified screenshot / screen recorder.
 *
 * Flow: hotkey -> fast screencopy freezes the screen -> fullscreen overlay with
 * an on-screen mode picker -> Enter confirms (region / fullscreen / window / record).
 * While recording, the same hotkey stops the recorder.
 */
PluginComponent {
    id: root

    pluginId: "shotrec"
    pluginService: PluginService

    readonly property var log: Log.scoped("shotrec")

    // ------------------------------------------------------------------ modes

    readonly property var modes: [
        {
            key: "shot",
            label: I18n.trFor("shotrec", "Screenshot"),
            hint: I18n.trFor("shotrec", "Captures the selection, or the whole screen if none"),
            icon: "crop_free"
        },
        {
            key: "windowShot",
            label: I18n.trFor("shotrec", "Window"),
            hint: I18n.trFor("shotrec", "Enter to capture the focused window"),
            icon: "crop_square"
        },
        {
            key: "record",
            label: I18n.trFor("shotrec", "Record"),
            hint: I18n.trFor("shotrec", "Records the selection, or the whole screen if none"),
            icon: "videocam"
        }
    ]

    property int modeIndex: 0
    readonly property string currentMode: modes[modeIndex].key
    readonly property bool isRecordMode: currentMode === "record"

    // ------------------------------------------------------------------ state

    // idle | live (surface mapped, grab still running) | selecting | recording
    property string phase: "idle"
    property string freezePath: ""
    property string pendingFreezePath: ""
    property var targetScreen: null
    property real captureScale: 1
    property rect selection: Qt.rect(0, 0, 0, 0)
    property bool hasSelection: false

    // recording
    property string recordPath: ""
    property string recordFinalPath: ""
    property string recordGeometry: ""
    property int recordSeconds: 0
    property string mixPath: ""
    property var recordTemps: []
    property bool recDone: true
    property bool mixDone: true
    property int recExit: 0

    // -------------------------------------------------------------- settings

    readonly property string imageDir: Paths.expandTilde(String(root.pluginData?.imageDir || "~/Pictures/Screenshots"))
    readonly property string videoDir: Paths.expandTilde(String(root.pluginData?.videoDir || "~/Videos"))
    readonly property bool copyToClipboard: root.pluginData?.copyToClipboard ?? true
    readonly property bool editAfterCapture: root.pluginData?.editAfterCapture ?? true
    readonly property int captureDelay: Number(root.pluginData?.captureDelay ?? 0)
    readonly property bool useHevc: root.pluginData?.useHevc ?? false

    readonly property string videoFormat: {
        const f = String(root.pluginData?.videoFormat || "mp4");
        return (f === "webm" || f === "mkv") ? f : "mp4";
    }
    readonly property string videoResolution: String(root.pluginData?.videoResolution || "native")
    readonly property string videoQuality: String(root.pluginData?.videoQuality || "high")
    // "auto" = let wf-recorder follow screen updates instead of a fixed -r.
    // Falls back to the legacy recordFps key so old settings carry over.
    readonly property string videoFps: String(root.pluginData?.videoFps ?? root.pluginData?.recordFps ?? "30")
    // off | system | mic | mixed. Falls back to the legacy recordAudio toggle
    // (a bare -a captured the default source, i.e. the microphone).
    readonly property string videoAudio: String(root.pluginData?.videoAudio ?? (root.pluginData?.recordAudio ? "mic" : "off"))

    readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache") + "/dms-shotrec"

    // ------------------------------------------------------------------ setup

    Component.onCompleted: {
        Proc.runCommand("shotrec.cachedir", ["mkdir", "-p", root.cacheDir], null, 0, 5000, root);
        Proc.runCommand("shotrec.imgdir", ["mkdir", "-p", root.imageDir], null, 0, 5000, root);
        Proc.runCommand("shotrec.videodir", ["mkdir", "-p", root.videoDir], null, 0, 5000, root);
        // Drop leftovers from a previous session (crash, kill, forced reload).
        Proc.runCommand("shotrec.sweep", ["sh", "-c", "rm -f \"$1\"/freeze-*.png \"$1\"/window-*.png \"$1\"/direct-*.png \"$1\"/edit-*.png \"$1\"/rec-*.mp4 \"$1\"/rec-*.webm \"$1\"/rec-*.mkv \"$1\"/mux-*.mp4 \"$1\"/mux-*.webm \"$1\"/mux-*.mkv \"$1\"/mix-*.wav", "sh", root.cacheDir], null, 0, 5000, null);
    }

    Component.onDestruction: root.cleanupFreeze()

    function cleanupFreeze() {
        if (!root.freezePath)
            return;
        Proc.runCommand("shotrec.rmfreeze", ["rm", "-f", root.freezePath], null, 0, 5000, null);
        root.freezePath = "";
    }

    // --------------------------------------------------------------- helpers

    function modeIndexOf(key) {
        for (let i = 0; i < root.modes.length; i++) {
            if (root.modes[i].key === key)
                return i;
        }
        return -1;
    }

    function timestamp() {
        const d = new Date();
        const p = (n) => String(n).padStart(2, "0");
        return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}-${p(d.getMinutes())}-${p(d.getSeconds())}`;
    }

    property int notifySeq: 0
    property int quickSettingsPing: 0

    // Unified channel: DMS itself owns org.freedesktop.Notifications, so this
    // lands in the notification center like any app's notification.
    function notifySaved(summary, body) {
        const seq = ++root.notifySeq;
        Proc.runCommand(`shotrec.notify.${seq}`, ["busctl", "--user", "call",
            "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications", "Notify",
            "susssasa{sv}i", "Shot & Rec", "0", "", summary, body, "0", "0", "5000"],
            null, 0, 5000, root);
    }

    /**
     * Selection rectangle -> geometry string in LOGICAL coordinates ("x,y WxH").
     *
     * wf-recorder takes logical coordinates here: under a fractional niri
     * scale they get multiplied by the output scale by the recorder itself,
     * so passing physical pixels would capture the wrong rectangle.
     */
    function logicalGeometry() {
        if (!root.hasSelection)
            return "";
        const x = Math.round(root.selection.x);
        const y = Math.round(root.selection.y);
        const w = Math.round(root.selection.width);
        const h = Math.round(root.selection.height);
        if (w <= 0 || h <= 0)
            return "";
        return `${x},${y} ${w}x${h}`;
    }

    /**
     * Selection rectangle -> geometry string in PHYSICAL pixels ("x,y WxH").
     * The frozen frame is a physical-pixel PNG, so ImageMagick crops need this.
     */
    function physicalGeometry() {
        if (!root.hasSelection)
            return "";
        const s = root.captureScale;
        const x = Math.round(root.selection.x * s);
        const y = Math.round(root.selection.y * s);
        const w = Math.round(root.selection.width * s);
        const h = Math.round(root.selection.height * s);
        if (w <= 0 || h <= 0)
            return "";
        return `${x},${y} ${w}x${h}`;
    }

    // --------------------------------------------------------------- actions

    /** Hotkey entry point: stops a running recording, otherwise opens the picker. */
    function toggle() {
        if (root.phase === "recording") {
            root.stopRecording();
            return "stopping";
        }
        if (editorWindow.visible)
            return "editing";
        if (root.phase === "selecting" || root.phase === "live") {
            root.cancelSelector();
            return "cancelled";
        }
        return root.openSelector("");
    }

    /** Freezes the screen and shows the mode picker. preferredMode may be "". */
    function openSelector(preferredMode) {
        const screen = CompositorService.getFocusedScreen();
        if (!screen)
            return "no screen";

        let index = preferredMode ? root.modeIndexOf(preferredMode) : -1;
        root.modeIndex = index >= 0 ? index : 0;

        root.targetScreen = screen;
        root.captureScale = CompositorService.getScreenScale(screen);
        root.selection = Qt.rect(0, 0, 0, 0);
        root.hasSelection = false;
        // Reopening while a previous frame is still around would leak it.
        root.cleanupFreeze();

        // Map the (still invisible) overlay surface first, then run the grab:
        // window creation/mapping overlaps with the capture instead of delaying
        // the first frame the user sees.
        root.phase = "live";
        selectorWindow.openPicker();

        const path = `${root.cacheDir}/freeze-${Date.now()}.png`;
        root.pendingFreezePath = path;
        // Unique sequence per grab: Proc.runCommand reuses one debounced entry
        // per id, so a shared id would let a newer open overwrite this
        // callback while the older process is still in flight (leaked frames,
        // wrong-phase transitions).
        const seq = ++root.grabSeq;
        // niri's native screencopy is ~15x faster than grim's PNG encode here
        // (0.08s vs 1.4s), which is the dominant part of the hotkey latency.
        const fileName = path.slice(root.cacheDir.length + 1);
        Proc.runCommand(`shotrec.grab.${seq}`, [
            "dms", "screenshot", "output", "-o", screen.name,
            "-d", root.cacheDir, "--filename", fileName,
            "--no-notify", "--no-clipboard"
        ], (output, exitCode) => {
            root.pendingFreezePath = "";
            if (seq !== root.grabSeq || root.phase !== "live") {
                // Superseded by a newer open, or cancelled while running.
                if (exitCode === 0)
                    Proc.runCommand(`shotrec.rmstale.${seq}`, ["rm", "-f", path], null, 0, 5000, null);
                return;
            }
            if (exitCode !== 0) {
                root.log.warn("freeze grab failed:", exitCode, output);
                root.phase = "idle";
                selectorWindow.closePicker();
                ToastService.showError(I18n.trFor("shotrec", "Could not capture the screen"));
                return;
            }
            root.freezePath = path;
            root.phase = "selecting";
            overlayContent.forceActiveFocus();
        }, 0, 10000, root);
        return "capturing";
    }

    property int grabSeq: 0

    function cancelSelector() {
        root.phase = "idle";
        selectorWindow.closePicker();
        root.cleanupFreeze();
    }

    function cycleMode(delta) {
        const count = root.modes.length;
        root.modeIndex = ((root.modeIndex + delta) % count + count) % count;
    }

    /** Enter pressed inside the picker. */
    function confirmSelection() {
        // Guards against auto-repeat / double Enter firing two captures.
        if (root.phase !== "selecting")
            return;
        const mode = root.currentMode;
        const shotGeometry = root.physicalGeometry();
        const recordGeometry = root.logicalGeometry();
        root.phase = "idle";
        selectorWindow.closePicker();

        if (mode === "windowShot") {
            root.captureWindow();
            return;
        }
        // Empty geometry = no selection = whole screen, for both modes below.
        if (mode === "record") {
            root.startRecording(recordGeometry);
            return;
        }
        root.captureShot(shotGeometry);
    }

    // ---------------------------------------------------------------- capture

    property int saveSeq: 0

    /**
     * Write a PNG source into imageDir, optionally cropped with a PHYSICAL
     * "x,y WxH" geometry. When the source is one of our cache-dir temp files
     * it is removed afterwards.
     *
     * Screenshots are always PNG: the screencopy capture is already a lossless
     * PNG, so a full-screen/window shot needs no decode+re-encode — just a
     * move. Only a region crop touches ffmpeg.
     */
    function saveImageFrom(source, geometry, summaryText) {
        const target = `${root.imageDir}/Screenshot from ${root.timestamp()}.png`;
        const seq = ++root.saveSeq;

        const finish = () => {
            if (source !== root.freezePath && source.startsWith(root.cacheDir))
                Proc.runCommand(`shotrec.rm.${seq}`, ["rm", "-f", source], null, 0, 5000, null);
            if (root.copyToClipboard) {
                Proc.runCommand(`shotrec.clip.${seq}`, ["sh", "-c", `wl-copy -t image/png < "$1"`, "sh", target], null, 0, 10000, root);
            }
            root.notifySaved(summaryText, target);
            root.cleanupFreeze();
        };

        // No crop: the captured PNG already is the final image, so just move
        // it. Running a codec would decode + re-encode for zero benefit.
        if (!geometry) {
            Proc.runCommand(`shotrec.mv.${seq}`, ["mv", source, target], (output, exitCode) => {
                if (exitCode !== 0) {
                    root.log.warn("mv failed:", exitCode, output);
                    ToastService.showError(I18n.trFor("shotrec", "Could not write the screenshot"));
                    return;
                }
                finish();
            }, 0, 10000, root);
            return;
        }

        const [origin, size] = geometry.split(" ");
        const [x, y] = origin.split(",");
        const [w, h] = size.split("x");
        Proc.runCommand(`shotrec.save.${seq}`, [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-i", source,
            "-vf", `crop=${w}:${h}:${x}:${y}`,
            "-compression_level", "2",
            target
        ], (output, exitCode) => {
            if (exitCode !== 0) {
                root.log.warn("ffmpeg crop failed:", exitCode, output);
                ToastService.showError(I18n.trFor("shotrec", "Could not write the screenshot"));
                return;
            }
            finish();
        }, 0, 30000, root);
    }

    function captureShot(geometry) {
        if (!root.freezePath) {
            ToastService.showError(I18n.trFor("shotrec", "No frozen frame available"));
            return;
        }
        if (root.captureDelay > 0) {
            delayTimer.interval = root.captureDelay * 1000;
            pendingShotGeometry = geometry;
            delayTimer.start();
            return;
        }
        root.writeShot(geometry);
    }

    property string pendingShotGeometry: ""

    property string shotNotifySummary: ""

    function writeShot(geometry) {
        const summary = root.shotNotifySummary || I18n.trFor("shotrec", "Screenshot saved");
        root.shotNotifySummary = "";
        if (root.editAfterCapture) {
            root.openEditor(root.freezePath, geometry, summary);
            return;
        }
        root.saveImageFrom(root.freezePath, geometry, summary);
    }

    function captureWindow() {
        // Grab the window PNG into the cache dir first: saveImageFrom then
        // applies the configured format/quality uniformly to every path.
        const fileName = `window-${Date.now()}.png`;
        Proc.runCommand("shotrec.window", [
            "dms", "screenshot", "window",
            "-d", root.cacheDir, "--filename", fileName,
            "--no-notify", "--no-clipboard"
        ], (output, exitCode) => {
            if (exitCode !== 0) {
                // No focused window (e.g. empty workspace): niri times out.
                // Degrade to a full screen shot from the freeze frame, same
                // "no selection = whole screen" philosophy as the other modes.
                root.log.warn("window capture failed, falling back to full screen:", exitCode, output);
                root.shotNotifySummary = I18n.trFor("shotrec", "No focused window — captured full screen");
                root.captureShot("");
                return;
            }
            const saved = String(output).trim().split("\n").pop();
            if (root.editAfterCapture)
                root.openEditor(saved, "", I18n.trFor("shotrec", "Screenshot saved"));
            else
                root.saveImageFrom(saved, "", I18n.trFor("shotrec", "Screenshot saved"));
        }, 0, 20000, root);
    }

    Timer {
        id: delayTimer
        repeat: false
        onTriggered: root.writeShot(root.pendingShotGeometry)
    }

    /**
     * Hotkey-free capture/record used by the shotNow / recordNow IPC calls.
     * geometry is logical "x,y WxH"; an empty string means the whole screen.
     */
    function grabDirect(geometry, record) {
        if (record) {
            // wf-recorder without -g records the whole screen; no grab needed.
            root.startRecording(geometry || "");
            return;
        }

        const screen = CompositorService.getFocusedScreen();
        if (!screen) {
            ToastService.showError(I18n.trFor("shotrec", "Could not capture the screen"));
            return;
        }
        const path = `${root.cacheDir}/direct-${Date.now()}.png`;
        const fileName = path.slice(root.cacheDir.length + 1);
        Proc.runCommand("shotrec.direct", [
            "dms", "screenshot", "output", "-o", screen.name,
            "-d", root.cacheDir, "--filename", fileName,
            "--no-notify", "--no-clipboard"
        ], (output, exitCode) => {
            if (exitCode !== 0) {
                root.log.warn("direct grab failed:", exitCode, output);
                ToastService.showError(I18n.trFor("shotrec", "Could not write the screenshot"));
                return;
            }
            let crop = "";
            if (geometry) {
                const s = CompositorService.getScreenScale(screen);
                const [origin, size] = String(geometry).split(" ");
                const [gx, gy] = origin.split(",");
                const [gw, gh] = size.split("x");
                crop = `${Math.round(Number(gx) * s)},${Math.round(Number(gy) * s)} ${Math.round(Number(gw) * s)}x${Math.round(Number(gh) * s)}`;
            }
            root.saveImageFrom(path, crop, I18n.trFor("shotrec", "Screenshot saved"));
        }, 0, 20000, root);
    }

    // ------------------------------------------------------------------ editor

    property string editorSummary: ""

    /**
     * Open the editor on `source`. When a selection `geometry` (physical
     * "x,y WxH") is given, the freeze frame is cropped to it FIRST so the
     * editor's base picture is the selection itself, not the whole screen.
     */
    function openEditor(source, geometry, summary) {
        root.editorSummary = summary;
        if (!geometry) {
            editorWindow.open(source, "");
            return;
        }
        const [origin, size] = geometry.split(" ");
        const [cx, cy] = origin.split(",");
        const [cw, ch] = size.split("x");
        const base = `${root.cacheDir}/edit-base-${Date.now()}.png`;
        const seq = ++root.saveSeq;
        Proc.runCommand(`shotrec.base.${seq}`, [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-i", source,
            "-vf", `crop=${cw}:${ch}:${cx}:${cy}`,
            "-compression_level", "2",
            base
        ], (output, exitCode) => {
            if (exitCode !== 0) {
                // Fall back to editing the full frame with the crop pre-applied.
                root.log.warn("editor base crop failed:", exitCode, output);
                editorWindow.open(source, geometry);
                return;
            }
            editorWindow.open(base, "");
        }, 0, 15000, root);
    }

    /**
     * Editor accepted. annPath "" keeps the zero-tool mv/crop path; otherwise
     * one ffmpeg call does crop (if any) + scales the alpha annotation layer
     * grabbed by the editor to the physical output size and overlays it.
     */
    function finishEditorSave(annPath, cropGeom, outW, outH) {
        const source = editorWindow.sourcePath;
        const summary = root.editorSummary || I18n.trFor("shotrec", "Screenshot saved");
        root.editorSummary = "";

        if (!annPath) {
            root.saveImageFrom(source, cropGeom, summary);
            return;
        }

        const out = `${root.cacheDir}/edit-final-${Date.now()}.png`;
        const seq = ++root.saveSeq;
        let base = "[0:v]null[b];";
        if (cropGeom) {
            const [origin, size] = cropGeom.split(" ");
            const [cx, cy] = origin.split(",");
            const [cw, ch] = size.split("x");
            base = `[0:v]crop=${cw}:${ch}:${cx}:${cy}[b];`;
        }
        const fc = `${base}[1:v]scale=${outW}:${outH}:flags=bicubic[a];[b][a]overlay=0:0:format=auto[v]`;
        Proc.runCommand(`shotrec.comp.${seq}`, [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-i", source, "-i", annPath,
            "-filter_complex", fc,
            "-map", "[v]",
            "-frames:v", "1",
            "-update", "1",
            "-compression_level", "2",
            out
        ], (output, exitCode) => {
            Proc.runCommand(`shotrec.rm.${seq}`, ["rm", "-f", annPath], null, 0, 5000, null);
            if (exitCode !== 0) {
                root.log.warn("annotate composite failed:", exitCode, output);
                ToastService.showError(I18n.trFor("shotrec", "Could not write the screenshot"));
                if (source !== root.freezePath && source.startsWith(root.cacheDir))
                    Proc.runCommand(`shotrec.rmsrc.${seq}`, ["rm", "-f", source], null, 0, 5000, null);
                root.cleanupFreeze();
                return;
            }
            if (source !== root.freezePath && source.startsWith(root.cacheDir))
                Proc.runCommand(`shotrec.rmsrc.${seq}`, ["rm", "-f", source], null, 0, 5000, null);
            root.saveImageFrom(out, "", summary);
        }, 0, 30000, root);
    }

    function finishEditorCancel() {
        const source = editorWindow.sourcePath;
        if (source && source !== root.freezePath && source.startsWith(root.cacheDir))
            Proc.runCommand("shotrec.rmcancel", ["rm", "-f", source], null, 0, 5000, null);
        root.editorSummary = "";
        root.cleanupFreeze();
    }

    // --------------------------------------------------------------- recording

    /** CRF for the configured quality tier; VP9's CRF scale runs higher than x264's. */
    function videoCrf(fmt) {
        const map = fmt === "webm"
            ? {high: 28, medium: 34, low: 40}
            : {high: 18, medium: 23, low: 28};
        return String(map[root.videoQuality] ?? map.high);
    }

    function startRecording(geometry) {
        const fmt = root.videoFormat;
        // "mixed" audio needs a mux step after the fact, so that case records
        // an intermediate into the cache dir instead of straight to videoDir.
        const target = `${root.videoDir}/Recording from ${root.timestamp()}.${fmt}`;
        const needsPost = root.videoAudio === "mixed";
        const intermediate = needsPost
            ? `${root.cacheDir}/rec-${Date.now()}.${fmt}` : target;

        const command = ["wf-recorder", "-y"];
        if (geometry)
            command.push("-g", geometry);
        if (root.videoFps !== "auto")
            command.push("-r", root.videoFps);
        if (root.videoResolution === "1080p")
            command.push("-F", "scale=-2:1080");
        else if (root.videoResolution === "720p")
            command.push("-F", "scale=-2:720");
        // The container picks the codec family; HEVC only applies to the
        // x264/x265 containers (webm cannot carry it).
        if (fmt === "webm") {
            command.push("-c", "libvpx-vp9");
            // wf-recorder keeps AAC for audio by default, which the WebM
            // muxer rejects ("Only VP8 or VP9..."); force opus.
            if (root.videoAudio === "system" || root.videoAudio === "mic")
                command.push("-C", "libopus");
        } else if (root.useHevc)
            command.push("-c", "libx265");
        command.push("-p", `crf=${root.videoCrf(fmt)}`);
        if (root.videoAudio === "system")
            command.push("--audio=@DEFAULT_MONITOR@");
        else if (root.videoAudio === "mic")
            command.push("--audio=@DEFAULT_SOURCE@");
        command.push("-f", intermediate);

        root.recordGeometry = geometry;
        root.recordPath = intermediate;
        root.recordFinalPath = needsPost ? target : "";
        root.mixPath = root.videoAudio === "mixed"
            ? `${root.cacheDir}/mix-${Date.now()}.wav` : "";
        root.recDone = false;
        root.mixDone = root.mixPath === "";
        root.recExit = -1;
        root.recordTemps = [];
        root.recordSeconds = 0;
        recorder.command = command;
        recorder.running = true;
        if (root.mixPath) {
            // wf-recorder takes a single audio device, so "system + mic" is
            // captured by a side ffmpeg that mixes both pulse sources into a
            // wav; completeRecording muxes it onto the video.
            mixer.command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-f", "pulse", "-i", "@DEFAULT_MONITOR@",
                "-f", "pulse", "-i", "@DEFAULT_SOURCE@",
                "-filter_complex", "amix=inputs=2:duration=longest:dropout_transition=0",
                "-ac", "2", root.mixPath];
            mixer.running = true;
        }
        root.phase = "recording";
        recordTimer.running = true;
        root.cleanupFreeze();
    }

    function stopRecording() {
        let stopping = false;
        if (recorder.running) {
            killRecorder.running = true;
            stopping = true;
        }
        if (mixer.running) {
            killMixer.running = true;
            stopping = true;
        }
        if (!stopping)
            root.tryCompleteRecording();
    }

    function tryCompleteRecording() {
        if (!root.recDone || !root.mixDone)
            return;
        recordTimer.running = false;
        killRecorder.running = false;
        killMixer.running = false;
        root.phase = "idle";

        if (root.recExit === 0 && root.recordPath) {
            if (root.recordFinalPath)
                root.postProcessRecording();
            else
                root.completeRecording(true); // written straight into videoDir
        } else if (root.recExit !== 0) {
            ToastService.showError(I18n.trFor("shotrec", "Recording failed"));
            root.completeRecording(false);
        }
    }

    property int postSeq: 0

    /**
     * Post-step for the cache-dir intermediate recorded with "mixed" audio:
     * mux the side-recorded wav onto the (stream-copied) video, then move the
     * result to videoDir. A failed mux falls through to the silent video, so
     * the recording is never lost just because the audio track broke.
     */
    function postProcessRecording() {
        const start = root.recordPath;
        const muxed = `${root.cacheDir}/mux-${Date.now()}.${root.videoFormat}`;
        root.recordTemps.push(muxed);
        const audioCodec = root.videoFormat === "webm" ? "libopus" : "aac";
        Proc.runCommand(`shotrec.mux.${++root.postSeq}`, ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-i", start, "-i", root.mixPath,
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "copy", "-c:a", audioCodec, "-shortest", muxed], (output, exitCode) => {
            if (exitCode !== 0) {
                root.log.warn("audio mux failed:", exitCode, output);
                root.finalizeRecording(start);
                return;
            }
            root.finalizeRecording(muxed);
        }, 0, 120000, root);
    }

    /** Move the cache-dir artifact into videoDir, then notify. */
    function finalizeRecording(source) {
        if (!source) {
            root.completeRecording(false);
            return;
        }
        if (source === root.recordFinalPath) {
            root.completeRecording(true);
            return;
        }
        Proc.runCommand(`shotrec.mv.${++root.postSeq}`, ["mv", source, root.recordFinalPath], (output, exitCode) => {
            if (exitCode !== 0) {
                root.log.warn("move failed:", exitCode, output);
                ToastService.showError(I18n.trFor("shotrec", "Could not move the recording"));
            }
            root.completeRecording(exitCode === 0);
        }, 0, 10000, root);
    }

    /** Final notification, temp cleanup and state reset. */
    function completeRecording(ok) {
        if (ok) {
            const seconds = root.recordSeconds;
            const size = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
            root.notifySaved(I18n.trFor("shotrec", "Recording saved (%1)").arg(size), root.recordFinalPath || root.recordPath);
        }
        const tempFiles = [root.recordPath, root.mixPath].concat(root.recordTemps)
            .filter(p => p && p.startsWith(root.cacheDir));
        if (tempFiles.length)
            Proc.runCommand(`shotrec.rmrec.${++root.postSeq}`, ["rm", "-f"].concat(tempFiles), null, 0, 10000, null);

        root.recordPath = "";
        root.recordFinalPath = "";
        root.recordGeometry = "";
        root.recordSeconds = 0;
        root.mixPath = "";
        root.recordTemps = [];
    }

    Timer {
        id: recordTimer
        interval: 1000
        repeat: true
        running: false
        onTriggered: root.recordSeconds++
    }

    Process {
        id: recorder
        running: false
        command: []
        onExited: (exitCode) => {
            root.recExit = exitCode;
            root.recDone = true;
            root.tryCompleteRecording();
        }
    }

    Process {
        id: killRecorder
        running: false
        command: ["kill", "-INT", String(recorder.processId)]
    }

    Process {
        id: mixer
        running: false
        command: []
        // SIGINT makes ffmpeg close the wav gracefully.
        onExited: () => {
            root.mixDone = true;
            root.tryCompleteRecording();
        }
    }

    Process {
        id: killMixer
        running: false
        command: ["kill", "-INT", String(mixer.processId)]
    }

    // ------------------------------------------------------------------- IPC

    IpcHandler {
        target: "shotrec"

        function toggle(): string {
            return root.toggle();
        }

        function open(): string {
            return root.openSelector("");
        }

        function cancel(): string {
            root.cancelSelector();
            return "cancelled";
        }

        function stop(): string {
            if (root.phase !== "recording")
                return "not recording";
            root.stopRecording();
            return "stopping";
        }

        function setMode(mode: string): string {
            return root.openSelector(mode);
        }

        function setModeOnly(mode: string): string {
            const index = root.modeIndexOf(mode);
            if (index < 0)
                return "unknown mode";
            root.modeIndex = index;
            return mode;
        }

        function status(): string {
            if (editorWindow.visible)
                return "editing";
            if (root.phase === "recording")
                return `recording ${root.recordSeconds}s ${root.recordGeometry || "fullscreen"}`;
            return root.phase;
        }

        /**
         * Capture straight away without the picker. geometry is a logical
         * "x,y WxH" string; empty means the whole screen.
         */
        function shotNow(geometry: string): string {
            root.grabDirect(geometry, false);
            return "capturing";
        }

        /** Start/stop recording straight away, same geometry convention as shotNow. */
        function recordNow(geometry: string): string {
            if (root.phase === "recording") {
                root.stopRecording();
                return "stopping";
            }
            root.grabDirect(geometry, true);
            return "recording";
        }

        /** Test/automation hook: set a logical-pixel selection rect in the picker. */
        function setSelection(x: int, y: int, w: int, h: int): string {
            if (root.phase !== "selecting")
                return "picker not open";
            root.selection = Qt.rect(x, y, w, h);
            root.hasSelection = w > 1 && h > 1;
            return root.logicalGeometry();
        }

        /** Open the bar pill's quick-settings popout (also usable from keybinds). */
        function quickSettings(): string {
            root.quickSettingsPing++;
            return "opening";
        }

        /** Test/automation hook: act as if Enter was pressed in the picker. */
        function confirm(): string {
            if (root.phase !== "selecting")
                return "picker not open";
            root.confirmSelection();
            return "confirmed";
        }

        /** Test/automation hook: act as if Enter was pressed in the editor. */
        function editorConfirm(): string {
            if (!editorWindow.visible)
                return "editor not open";
            editorWindow.saveEdit();
            return "saving";
        }

        /** Test/automation hook: draw a diagonal arrow in the editor. */
        function editorTestArrow(): string {
            if (!editorWindow.visible)
                return "editor not open";
            editorWindow.addTestArrow();
            return "drawn";
        }

        /** Test/automation hook: draw a mosaic stroke in the editor. */
        function editorTestMosaic(): string {
            if (!editorWindow.visible)
                return "editor not open";
            editorWindow.addTestMosaic();
            return "drawn";
        }

        /** Test/automation hook: act as if Esc was pressed in the editor. */
        function editorCancel(): string {
            if (!editorWindow.visible)
                return "editor not open";
            editorWindow.cancelEdit();
            return "cancelled";
        }
    }

    // ------------------------------------------------------------------- UI

    // Post-capture annotation editor: a real desktop window (FloatingWindow,
    // the SshMan precedent), independent from the picker's layer surface.
    ShotRecEditor {
        id: editorWindow

        cacheDir: root.cacheDir

        onAccepted: (annPath, cropGeom, outWidth, outHeight) => root.finishEditorSave(annPath, cropGeom, outWidth, outHeight)
        onCancelled: root.finishEditorCancel()
    }

    // Fullscreen layer-shell surface: own window so it is not tied to the
    // DankModal lifecycle (opening another modal must not close the picker).
    PanelWindow {
        id: selectorWindow

        visible: false
        color: "transparent"
        screen: root.targetScreen

        WlrLayershell.namespace: "dms:plugins:shotrec"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.exclusiveZone: -1
        // Only grab the keyboard once the frozen frame is on screen; during
        // the "live" (transparent pre-mapping) phase input must stay put.
        WlrLayershell.keyboardFocus: visible && root.phase === "selecting" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        function openPicker() {
            visible = true;
        }

        function closePicker() {
            visible = false;
        }

        ShotRecOverlay {
            id: overlayContent

            anchors.fill: parent

            modes: root.modes
            modeIndex: root.modeIndex
            freezePath: root.freezePath
            pixelScale: root.captureScale
            selection: root.selection
            hasSelection: root.hasSelection
            isRecordMode: root.isRecordMode
            ready: root.phase === "selecting"

            onModeStep: (delta) => root.cycleMode(delta)
            onModePicked: (index) => {
                root.modeIndex = index;
            }
            onSelectionUpdated: (rect) => {
                root.selection = rect;
                root.hasSelection = rect.width > 1 && rect.height > 1;
            }
            onAccepted: root.confirmSelection()
            onCancelled: root.cancelSelector()
        }
    }
}
