pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

/**
 * Headless file-transfer engine for sshMan. Browses the remote filesystem
 * through `ssh <alias> find … -printf` and copies items with rsync (scp
 * fallback), all with BatchMode so a password prompt can never hang the UI:
 * a host without key auth lands in an explicit error state instead. One
 * Process per transfer, streamed progress parsed from the \r-refreshed
 * meter lines, cancel via SIGTERM (Quickshell 0.3 has no terminate).
 */
Item {
    id: root

    /// Daemon instance for notify(), settings and alias validation.
    property var daemon: null
    readonly property string ns: "sshMan"

    property string alias: ""
    property string homePath: ""
    property string currentPath: ""
    property bool loading: false
    /// "", "auth", "hostkey", "network", "remote-tools" or "listing".
    property string loadError: ""
    property string loadErrorMessage: ""
    /// [{name, path, isDir, isFile, isSymlink, size, modified}]
    property var entries: []
    /// Mirror of _rows with fresh objects on every change.
    property var transfers: []
    /// Records skipped because the remote name contains a newline.
    property int badNames: 0

    /// rsync once failed as missing and the engine switched to plain scp for
    /// the rest of the session.
    property bool preferRsync: true

    readonly property int maxParallel: 4

    property var _rows: []
    property var _jobs: ({})
    property int _nextId: 1

    function tr(text) {
        return I18n.trFor(root.ns, text);
    }

    function quoteShell(text) {
        return "'" + text.replace(/'/g, "'\\''") + "'";
    }

    function remoteSpec(path) {
        return root.alias + ":" + path;
    }

    function parentOf(path) {
        const trimmed = String(path).replace(/\/+$/, "");
        if (trimmed === "" || trimmed === "/")
            return "/";
        const cut = trimmed.lastIndexOf("/");
        return cut <= 0 ? "/" : trimmed.substring(0, cut);
    }

    // ---- One-shot buffered jobs -----------------------------------------------

    Component {
        id: oneShotComp

        Item {
            id: oneShot

            property var command: []
            /// 0 disables the watchdog.
            property int timeoutMs: 0
            property string stdout: ""
            property string stderr: ""
            property bool timedOut: false

            signal finished(bool ok, int exitCode, string out, string err)

            Process {
                id: proc

                command: oneShot.command
                running: true

                stdout: SplitParser {
                    splitMarker: "\n"
                    onRead: line => {
                        oneShot.stdout += line + "\n";
                    }
                }
                stderr: SplitParser {
                    splitMarker: "\n"
                    onRead: line => {
                        oneShot.stderr += line + "\n";
                    }
                }
                onExited: exitCode => {
                    watchdog.stop();
                    oneShot.finished(exitCode === 0 && !oneShot.timedOut,
                        exitCode, oneShot.stdout, oneShot.stderr);
                }
            }

            Timer {
                id: watchdog

                interval: oneShot.timeoutMs
                running: oneShot.timeoutMs > 0
                onTriggered: {
                    if (!proc.running)
                        return;
                    oneShot.timedOut = true;
                    proc.signal("SIGTERM");
                }
            }
        }
    }

    function startOneShot(command, timeoutMs, callback) {
        const oneShot = oneShotComp.createObject(root, {
            command: command,
            timeoutMs: timeoutMs
        });
        oneShot.finished.connect((ok, exitCode, out, err) => {
            callback(ok, exitCode, out, err);
            oneShot.destroy();
        });
    }

    // ---- Remote browsing -------------------------------------------------------

    function connectArgs() {
        const timeout = root.daemon ? root.daemon.settingTestTimeout : 5;
        return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=" + timeout];
    }

    function sshTimeoutMs() {
        const timeout = root.daemon ? root.daemon.settingTestTimeout : 5;
        return (timeout + 10) * 1000;
    }

    /// Maps an ssh failure to a pane error state. Everything rides on key
    /// auth, so the auth case is the one the user needs spelled out.
    function classifyLoadError(exitCode, err) {
        const text = String(err);
        if (/Permission denied \((publickey|password)|No supported authentication methods|Too many authentication failures/.test(text)) {
            root.loadError = "auth";
            root.loadErrorMessage = root.tr("Key authentication required — run ssh-copy-id %1 in a terminal first").arg(root.alias);
            return;
        }
        if (/Host key verification failed/.test(text)) {
            root.loadError = "hostkey";
            root.loadErrorMessage = root.tr("Host key not trusted yet — connect once with the link button first");
            return;
        }
        if (exitCode === 255 || /Connection refused|timed out|Name or service not known|No route to host|Connection closed|Broken pipe/.test(text)) {
            root.loadError = "network";
            const lines = text.split("\n").filter(Boolean);
            root.loadErrorMessage = root.tr("Host unreachable") + ": "
                + (lines.length > 0 ? lines[lines.length - 1] : root.alias);
            return;
        }
        if (/printf|unknown (option|predicate)|unrecognized/.test(text)) {
            root.loadError = "remote-tools";
            root.loadErrorMessage = root.tr("Remote GNU find is required for browsing");
            return;
        }
        root.loadError = "listing";
        root.loadErrorMessage = text.trim() === "" ? root.tr("Remote listing failed") : text.trim();
    }

    function openFor(alias) {
        root.alias = String(alias);
        root.homePath = "";
        root.currentPath = "";
        root.entries = [];
        root.badNames = 0;
        root.loadError = "";
        root.loadErrorMessage = "";
        root.loading = true;
        root.startOneShot(root.connectArgs().concat([root.alias, "pwd"]),
            root.sshTimeoutMs(), (ok, exitCode, out, err) => {
            if (!ok) {
                root.loading = false;
                root.classifyLoadError(exitCode, err);
                return;
            }
            const home = String(out).trim();
            if (home === "" || !home.startsWith("/")) {
                root.loading = false;
                root.loadError = "listing";
                root.loadErrorMessage = root.tr("Remote listing failed");
                return;
            }
            root.homePath = home;
            root.listDir(home);
        });
    }

    function listDir(path) {
        root.loading = true;
        // One tab-separated record per entry: own type, target type (follows
        // symlinks so dir-links navigate), size, mtime, name. The name is the
        // last field, so spaces in it survive; only newlines cannot, and those
        // records are counted and skipped.
        const format = '"%y\\t%Y\\t%s\\t%TY-%Tm-%Td %TH:%TM\\t%f\\n"';
        const remoteCmd = "find " + root.quoteShell(path)
            + " -mindepth 1 -maxdepth 1 -printf " + format;
        root.startOneShot(root.connectArgs().concat([root.alias, remoteCmd]),
            root.sshTimeoutMs(), (ok, exitCode, out, err) => {
            if (!ok) {
                root.loading = false;
                root.classifyLoadError(exitCode, err !== "" ? err : out);
                return;
            }
            const entries = [];
            let skipped = 0;
            String(out).split("\n").forEach(line => {
                if (line === "")
                    return;
                // Split off exactly the first four tabs.
                const cuts = [];
                let cursor = -1;
                for (let i = 0; i < 4; i += 1) {
                    cursor = line.indexOf("\t", cursor + 1);
                    if (cursor < 0)
                        break;
                    cuts.push(cursor);
                }
                if (cuts.length < 4) {
                    skipped += 1;
                    return;
                }
                const ownType = line.substring(0, cuts[0]);
                const targetType = line.substring(cuts[0] + 1, cuts[1]);
                const size = Number(line.substring(cuts[1] + 1, cuts[2]));
                const modified = line.substring(cuts[2] + 1, cuts[3]);
                const name = line.substring(cuts[3] + 1);
                if (name === "" || name.indexOf("\n") >= 0) {
                    skipped += 1;
                    return;
                }
                const isDir = targetType === "d";
                const joined = path === "/" ? "/" + name : path + "/" + name;
                entries.push({
                    name: name,
                    path: joined,
                    isDir: isDir,
                    isFile: targetType === "f" || targetType === "N"
                        || ownType === "f",
                    isSymlink: ownType === "l",
                    size: Number.isFinite(size) ? size : 0,
                    modified: modified
                });
            });
            entries.sort((a, b) => {
                if (a.isDir !== b.isDir)
                    return a.isDir ? -1 : 1;
                return a.name.localeCompare(b.name);
            });
            root.currentPath = path;
            root.entries = entries;
            root.badNames = skipped;
            root.loadError = "";
            root.loadErrorMessage = "";
            root.loading = false;
        });
    }

    // ---- Transfers ---------------------------------------------------------------

    /**
     * A transfer process streams progress on either stdout or stderr
     * (rsync moved streams across versions), so both feed one handler.
     * Lines matching the rsync/scp meters update the row; everything else is
     * kept as the error tail, used only when the exit code says failure.
     */
    Component {
        id: transferComp

        Item {
            id: tJob

            required property int transferId
            property var argv: []
            property bool isRsync: true
            property string errorTail: ""
            property bool sawProgress: false
            property bool cancelRequested: false

            signal progressed(int percent, string rate)
            signal terminated(int exitCode)

            function handleChunk(chunk) {
                String(chunk).split(/[\r\n]/).forEach(part => {
                    const line = part.trim();
                    if (line === "")
                        return;
                    const rsync = line.match(
                        /^[\d.,\s]+?(\d{1,3})%\s+(\S+\/s)\s/);
                    if (rsync) {
                        tJob.sawProgress = true;
                        tJob.progressed(Number(rsync[1]), rsync[2]);
                        return;
                    }
                    const scp = line.match(
                        /(\d{1,3})%\s+\S+\s+(\S+\/s)\s+(?:\d+:)?\d{2}:\d{2}\s*$/);
                    if (scp) {
                        tJob.sawProgress = true;
                        tJob.progressed(Number(scp[1]), scp[2]);
                        return;
                    }
                    if (!tJob.sawProgress)
                        tJob.errorTail += line + "\n";
                    if (tJob.errorTail.length > 800)
                        tJob.errorTail = tJob.errorTail.substring(
                            tJob.errorTail.length - 800);
                });
            }

            function cancel() {
                tJob.cancelRequested = true;
                if (tProc.running)
                    tProc.signal("SIGTERM");
            }

            Process {
                id: tProc

                command: tJob.argv
                running: true

                stdout: SplitParser {
                    splitMarker: "\r"
                    onRead: chunk => {
                        tJob.handleChunk(chunk);
                    }
                }
                stderr: SplitParser {
                    splitMarker: "\r"
                    onRead: chunk => {
                        tJob.handleChunk(chunk);
                    }
                }
                onExited: exitCode => {
                    tJob.terminated(exitCode);
                }
            }
        }
    }

    function runningCount() {
        return Object.keys(root._jobs).length;
    }

    function rowById(id) {
        return root._rows.find(row => row.id === id) ?? null;
    }

    function publishRows() {
        root.transfers = root._rows.map(row => ({
            id: row.id,
            name: row.name,
            direction: row.direction,
            state: row.state,
            percent: row.percent,
            rate: row.rate,
            message: row.message
        }));
    }

    /// names: entries from the source pane. Builds queued rows, then pumps.
    function startUpload(localDir, names) {
        root.enqueue(names, "up", localDir, root.currentPath);
    }

    function startDownload(localDir, names) {
        root.enqueue(names, "down", localDir, root.currentPath);
    }

    function enqueue(names, direction, localDir, remoteDir) {
        const added = [];
        names.forEach(item => {
            const name = String(item.name);
            const localPath = localDir === "/" ? "/" + name : localDir + "/" + name;
            const remotePath = remoteDir === "/" ? "/" + name : remoteDir + "/" + name;
            added.push({
                id: root._nextId,
                name: name,
                direction: direction,
                state: "queued",
                percent: -1,
                rate: "",
                message: "",
                isDir: item.isDir === true,
                localPath: localPath,
                remotePath: remotePath,
                retried: false
            });
            root._nextId += 1;
        });
        if (added.length === 0)
            return;
        root._rows = root._rows.concat(added);
        root.publishRows();
        root.pump();
    }

    function buildArgv(row, useRsync) {
        const timeout = root.daemon ? root.daemon.settingTestTimeout : 5;
        if (useRsync) {
            // rsync ≥3.2.4 shell-escapes remote paths itself; pre-escaping
            // lands literal backslashes in file names (verified against a
            // 3.5.0 remote). Older remote rsync needs plain names instead.
            const argv = ["rsync", "-a", "--info=progress2", "--no-motd",
                "-e", "ssh -o BatchMode=yes -o ConnectTimeout=" + timeout, "--"];
            if (row.direction === "up")
                return argv.concat([row.localPath, root.remoteSpec(row.remotePath)]);
            return argv.concat([root.remoteSpec(row.remotePath), row.localPath]);
        }
        // scp defaults to the SFTP protocol, which takes remote paths
        // literally, so no remote-shell escaping there.
        const argv = ["scp", "-r", "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=" + timeout, "--"];
        if (row.direction === "up")
            return argv.concat([row.localPath, root.remoteSpec(row.remotePath)]);
        return argv.concat([root.remoteSpec(row.remotePath), row.localPath]);
    }

    function launch(row) {
        const useRsync = root.preferRsync;
        const job = transferComp.createObject(root, {
            transferId: row.id,
            argv: root.buildArgv(row, useRsync),
            isRsync: useRsync
        });
        const merged = {};
        Object.keys(root._jobs).forEach(key => {
            merged[key] = root._jobs[key];
        });
        merged[row.id] = job;
        root._jobs = merged;
        job.progressed.connect((percent, rate) => {
            const live = root.rowById(row.id);
            if (live === null || live.state !== "running")
                return;
            live.percent = percent;
            live.rate = rate;
            root.publishRows();
        });
        job.terminated.connect(exitCode => {
            root.finishTransfer(row.id, exitCode, job);
        });
        row.state = "running";
        root.publishRows();
    }

    function finishTransfer(id, exitCode, job) {
        const row = root.rowById(id);
        if (row === null)
            return;
        const fresh = {};
        Object.keys(root._jobs).forEach(key => {
            if (Number(key) !== id)
                fresh[key] = root._jobs[key];
        });
        root._jobs = fresh;
        job.destroy();

        if (job.cancelRequested) {
            row.state = "cancelled";
            row.message = root.tr("Transfer cancelled");
            root.publishRows();
            root.afterFinish();
            return;
        }
        if (exitCode === 0) {
            row.state = "done";
            row.percent = 100;
            row.message = "";
            root.publishRows();
            if (row.direction === "up")
                root.listDir(root.currentPath);
            root.afterFinish();
            return;
        }
        // rsync missing on the far side: the external command dies with 127
        // before any progress, so retry this row with plain scp once and
        // stop preferring rsync for the session.
        if (job.isRsync && !job.sawProgress && !row.retried
            && (exitCode === 127 || /command not found|No such file/.test(job.errorTail))) {
            row.retried = true;
            root.preferRsync = false;
            row.state = "queued";
            root.publishRows();
            root.pump();
            return;
        }
        row.state = "failed";
        const tail = String(job.errorTail).split("\n").filter(Boolean);
        row.message = tail.length > 0 ? tail[tail.length - 1]
            : root.tr("Transfer failed") + " (" + exitCode + ")";
        root.publishRows();
        root.afterFinish();
    }

    /// One summary notification when a batch drains completely.
    function afterFinish() {
        if (root.runningCount() > 0)
            return;
        const pending = root._rows.filter(row => row.state === "queued");
        if (pending.length > 0) {
            root.pump();
            return;
        }
        const finishedRows = root._rows.filter(row => row.notified !== true
            && (row.state === "done" || row.state === "failed"
                || row.state === "cancelled"));
        if (finishedRows.length === 0)
            return;
        const failed = finishedRows.filter(row => row.state === "failed").length;
        const cancelled = finishedRows.filter(
            row => row.state === "cancelled").length;
        const done = finishedRows.length - failed - cancelled;
        const summary = I18n.trFor(root.ns, "%1 done · %2 failed · %3 cancelled")
            .arg(done).arg(failed).arg(cancelled);
        finishedRows.forEach(row => {
            row.notified = true;
        });
        if (root.daemon && root.daemon.settingNotifyTransfer !== true)
            return;
        if (root.daemon) {
            root.daemon.notify(failed + cancelled === 0
                ? root.tr("Transfers complete") : root.tr("Transfers finished"),
            summary, failed + cancelled === 0 ? "check_circle" : "error");
        }
    }

    function pump() {
        while (root.runningCount() < root.maxParallel) {
            const next = root._rows.find(row => row.state === "queued");
            if (next === undefined)
                return;
            root.launch(next);
        }
    }

    function cancel(id) {
        const job = root._jobs[id];
        if (job !== undefined) {
            job.cancel();
            return;
        }
        const row = root.rowById(id);
        if (row !== null && row.state === "queued") {
            row.state = "cancelled";
            row.message = root.tr("Transfer cancelled");
            root.publishRows();
        }
    }

    function dismiss(id) {
        const row = root.rowById(id);
        if (row === null || row.state === "running" || row.state === "queued")
            return;
        root._rows = root._rows.filter(entry => entry.id !== id);
        root.publishRows();
    }

    function hasActive() {
        return root._rows.some(row => row.state === "running"
            || row.state === "queued");
    }
}
