pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

/**
 * sshMan daemon. Parses ~/.ssh/config (with Includes) through SshConfigParser,
 * maintains a managed block of extra hosts in that same file, opens sessions
 * in the default terminal, probes reachability with BatchMode ssh, polls the
 * process table for live ssh sessions, and exposes everything over IPC. The
 * bar widget and the launcher read this instance through PluginService.
 */
PluginComponent {
    id: root

    readonly property string ns: "sshMan"

    property string configPath: (Quickshell.env("HOME") || "") + "/.ssh/config"

    /// [{alias, hostname, user, port, proxyJump, identity, wildcard, managed, file}]
    property var hosts: []
    property var warnings: []
    property bool configExists: false
    property string mainText: ""
    /// [{pid, etime, target, alias, kind, connected}]
    property var sessions: []
    /// alias → {ok, message, at}
    property var testResults: ({})
    /// ["<kind>:<alias>", ...] for every in-flight operation. Reassigned rather
    /// than mutated so UI bindings invalidate.
    property var activeOps: []
    property string lastParseAt: ""
    property string lastPollAt: ""

    // Settings mirrored from pluginData so imperative code has plain types.
    property string settingTerminal: ""
    property int settingTestTimeout: 5
    property int settingPollSeconds: 5
    property bool settingNotifyNew: true
    property bool settingNotifyEnd: false
    property bool settingShowUnresolved: true
    property bool settingNotifyTransfer: true

    property var _lastSessions: ({})
    property bool _sessionBaseline: false

    SshConfigParser {
        id: configParser
    }

    // Persistent so in-flight transfers survive the window being closed;
    // the window itself only toggles visibility.
    SshFileManager {
        id: fileManager

        daemon: root
    }

    // ---- Settings ----------------------------------------------------------

    /// One default per key, shared with the settings page.
    function settingBool(key, fallback) {
        const value = root.pluginData[key];
        return value === undefined ? fallback : value === true;
    }

    function loadSettings() {
        root.settingTerminal = String(root.pluginData.terminalCommand || "");
        const testTimeout = Number(root.pluginData.testTimeoutSeconds);
        root.settingTestTimeout = Number.isFinite(testTimeout) && testTimeout >= 2
            && testTimeout <= 60 ? testTimeout : 5;
        const poll = Number(root.pluginData.pollIntervalSeconds);
        root.settingPollSeconds = Number.isFinite(poll) && poll >= 2
            && poll <= 300 ? poll : 5;
        root.settingNotifyNew = root.settingBool("notifyOnNewSession", true);
        root.settingNotifyEnd = root.settingBool("notifyOnSessionEnd", false);
        root.settingShowUnresolved = root.settingBool("showUnresolved", true);
        root.settingNotifyTransfer = root.settingBool("notifyOnTransferComplete", true);
    }

    onPluginDataChanged: root.loadSettings()

    // ---- Whitelists ---------------------------------------------------------

    /// Aliases go into sh -c (escaped) and into Host lines, so keep them to a
    /// charset that cannot quote-escape or inject whitespace.
    function safeAlias(alias) {
        return /^[A-Za-z0-9._-]{1,64}$/.test(String(alias || ""));
    }

    function safeHostName(host) {
        return /^[A-Za-z0-9._:\[\]-]{1,253}$/.test(String(host || ""));
    }

    function safePort(port) {
        const value = Number(port);
        return Number.isInteger(value) && value >= 1 && value <= 65535;
    }

    function findHost(alias) {
        return root.hosts.find(host => host.alias === String(alias)) ?? null;
    }

    // ---- Notifications -------------------------------------------------------

    function notify(title, body, icon) {
        Quickshell.execDetached([
            "dms", "notify", title, body,
            "--icon", icon,
            "--app", "SSH Manager"
        ]);
    }

    // ---- Config loading -------------------------------------------------------

    /// False when a parse is already running, which callers must not ignore
    /// when they intend to mutate the config off the fresh result.
    function reloadConfig(onDone) {
        if (configParser.running)
            return false;
        configParser.loadConfig(root.configPath, result => {
            root.hosts = result.hosts;
            root.warnings = result.warnings;
            root.configExists = result.configExists;
            root.mainText = result.mainText === null ? "" : result.mainText;
            root.lastParseAt = Qt.formatDateTime(new Date(), "HH:mm:ss");
            try {
                if (root.pluginService)
                    root.pluginService.requestLauncherUpdate(root.pluginId);
            } catch (error) {
                console.warn("[sshMan] launcher update not supported");
            }
            if (onDone)
                onDone();
        });
        return true;
    }

    // ---- One-shot jobs ---------------------------------------------------------

    /**
     * Captures both streams, unlike Proc.runCommand, which is what ssh and
     * udisks-style tools need to explain a failure. Quickshell 0.3 Process has
     * no terminate method, so a watchdog runs a separate argv `kill`
     * against the recorded pid.
     */
    Component {
        id: jobComp

        Item {
            id: job

            property var command: []
            property string output: ""
            /// 0 disables the watchdog.
            property int timeoutMs: 0

            signal finished(bool ok, string message)

            /// Set when the watchdog fired, so callers can tell a timeout from
            /// a real exit instead of reading a 143 as "host unreachable".
            property bool timedOut: false

            Process {
                id: jobProcess

                command: job.command
                running: true

                stdout: SplitParser {
                    splitMarker: "\n"
                    onRead: line => {
                        job.output += line + "\n";
                    }
                }
                stderr: SplitParser {
                    splitMarker: "\n"
                    onRead: line => {
                        job.output += line + "\n";
                    }
                }
                onExited: exitCode => {
                    watchdog.stop();
                    const message = job.timedOut
                        ? I18n.trFor("sshMan", "Timed out")
                        : job.output.trim();
                    job.finished(exitCode === 0, message);
                }
            }

            Timer {
                id: watchdog

                interval: job.timeoutMs
                running: job.timeoutMs > 0
                onTriggered: {
                    if (!jobProcess.running)
                        return;
                    job.timedOut = true;
                    jobProcess.signal("SIGTERM");
                }
            }
        }
    }

    function startJob(command, timeoutMs, callback) {
        const job = jobComp.createObject(root, {
            command: command,
            timeoutMs: timeoutMs
        });
        job.finished.connect((ok, message) => {
            callback(ok, message);
            job.destroy();
        });
    }

    function opActive(kind, alias) {
        return root.activeOps.indexOf(kind + ":" + alias) >= 0;
    }

    function beginOp(kind, alias) {
        if (root.opActive(kind, alias))
            return false;
        root.activeOps = root.activeOps.concat([kind + ":" + alias]);
        return true;
    }

    function endOp(kind, alias) {
        root.activeOps = root.activeOps.filter(entry => entry !== kind + ":" + alias);
    }

    // ---- Connect -------------------------------------------------------------

    /**
     * Settings override → DMS' own resolution (terminalOverride, then $TERMINAL)
     * → first terminal found by DMS' install probe → xterm. Stopping earlier
     * left connects inert on any setup where $TERMINAL is unset, even though
     * DMS core always falls back (`SessionData.resolveTerminal() || "xterm"`).
     */
    function terminalCommand() {
        if (root.settingTerminal.trim() !== "")
            return root.settingTerminal.trim();
        try {
            const resolved = String(SessionData.resolveTerminal() || "");
            if (resolved !== "")
                return resolved;
            const installed = SessionData.installedTerminals;
            if (Array.isArray(installed) && installed.length > 0)
                return String(installed[0]);
        } catch (error) {
            console.warn("[sshMan] SessionData not reachable, using $TERMINAL");
            const env = String(Quickshell.env("TERMINAL") || "");
            if (env !== "")
                return env;
        }
        return "xterm";
    }

    function shellQuote(text) {
        return "'" + text.replace(/'/g, "'\\''") + "'";
    }

    /// Same convention as DMS core (SessionService.launchDesktopEntry):
    /// [terminal, "-e", "sh", "-c", cmd]. The alias is whitelisted first and
    /// single-quoted on top, so nothing can break out.
    function openSession(alias) {
        if (!root.safeAlias(alias))
            return I18n.trFor(root.ns, "Invalid host alias");
        // terminalCommand() always resolves to something, so there is no
        // "no terminal" state to report; the worst case is the xterm attempt
        // failing silently like any missing binary.
        const argv = root.terminalCommand().split(/\s+/).filter(Boolean);
        const shellCmd = "ssh " + root.shellQuote(String(alias));
        Quickshell.execDetached({
            command: argv.concat(["-e", "sh", "-c", shellCmd])
        });
        return I18n.trFor(root.ns, "Opening") + " " + alias;
    }

    function copyCommand(alias) {
        if (!root.safeAlias(alias))
            return I18n.trFor(root.ns, "Invalid host alias");
        Quickshell.execDetached(["dms", "cl", "copy", "ssh " + alias]);
        return I18n.trFor(root.ns, "Copied ssh command for") + " " + alias;
    }

    // ---- File manager ------------------------------------------------------------

    function openFiles(alias) {
        if (!root.safeAlias(alias))
            return I18n.trFor(root.ns, "Invalid host alias");
        const host = root.findHost(alias);
        if (host === null)
            return I18n.trFor(root.ns, "Host not found");
        if (host.wildcard)
            return I18n.trFor(root.ns, "Cannot browse a pattern template host");
        fileManager.openHost(host);
        return I18n.trFor(root.ns, "Opening files for") + " " + alias;
    }

    // ---- Test ------------------------------------------------------------------

    function testHost(alias) {
        if (!root.safeAlias(alias))
            return I18n.trFor(root.ns, "Invalid host alias");
        if (!root.beginOp("test", alias))
            return I18n.trFor(root.ns, "Operation already running for this host");
        const timeout = root.settingTestTimeout;
        root.startJob(["ssh", "-o", "BatchMode=yes", "-o",
            "ConnectTimeout=" + timeout, String(alias), "true"],
        (timeout + 5) * 1000, (ok, message) => {
            root.endOp("test", alias);
            const entry = {
                ok: ok,
                message: message === "" ? (ok ? I18n.trFor(root.ns, "Reachable")
                    : I18n.trFor(root.ns, "Unreachable")) : message,
                at: Qt.formatDateTime(new Date(), "HH:mm:ss")
            };
            const merged = {};
            Object.keys(root.testResults).forEach(key => {
                merged[key] = root.testResults[key];
            });
            merged[alias] = entry;
            root.testResults = merged;
            if (ok)
                root.notify(I18n.trFor(root.ns, "Host reachable"), alias, "check_circle");
        });
        return I18n.trFor(root.ns, "Testing") + " " + alias;
    }

    // ---- Managed hosts ----------------------------------------------------------

    /// Emitted once a write has landed and the host list has been reparsed,
    /// carrying the surviving alias ("" for a removal). The widget form clears
    /// on this rather than guessing success from the synchronous return,
    /// which cannot see an asynchronous write completion.
    signal hostWritten(string alias)

    function addHost(alias, hostName, user, port) {
        const trimmedAlias = String(alias || "").trim();
        const trimmedHost = String(hostName || "").trim();
        const trimmedUser = String(user || "").trim();
        const trimmedPort = String(port || "").trim();
        if (!root.safeAlias(trimmedAlias))
            return I18n.trFor(root.ns,
                "Alias may use letters, digits, dot, dash and underscore (max 64)");
        if (!root.safeHostName(trimmedHost))
            return I18n.trFor(root.ns, "Invalid host name");
        if (trimmedUser !== "" && !/^[A-Za-z0-9._-]{1,64}$/.test(trimmedUser))
            return I18n.trFor(root.ns, "Invalid user name");
        if (trimmedPort !== "" && !root.safePort(trimmedPort))
            return I18n.trFor(root.ns, "Port must be between 1 and 65535");
        // First-wins means a user stanza of the same name would shadow the
        // managed one, so refuse instead of writing a dead Host line. The
        // duplicate check runs against a freshly parsed file: the config may
        // have been edited outside the daemon since the last parse, and
        // mutating the cached text would then drop those edits.
        if (!root.beginOp("write", trimmedAlias))
            return I18n.trFor(root.ns, "Operation already running for this host");
        const started = root.reloadConfig(() => {
            if (root.findHost(trimmedAlias) !== null) {
                root.endOp("write", trimmedAlias);
                ToastService.showError(I18n.trFor(root.ns, "Config update failed"),
                    I18n.trFor(root.ns, "A host with this name already exists"));
                return;
            }
            const stanza = configParser.buildStanza(trimmedAlias, trimmedHost,
                trimmedUser, trimmedPort === "22" ? "" : trimmedPort);
            const newText = configParser.insertManagedHost(
                root.configExists ? root.mainText : null, stanza);
            root.writeConfig(newText, () => {
                root.endOp("write", trimmedAlias);
                root.reloadConfig(() => root.hostWritten(trimmedAlias));
            }, message => {
                root.endOp("write", trimmedAlias);
                ToastService.showError(I18n.trFor(root.ns, "Config write failed"), message);
            });
        });
        if (!started) {
            root.endOp("write", trimmedAlias);
            return I18n.trFor(root.ns, "Config is reloading, try again");
        }
        return I18n.trFor(root.ns, "Host added") + ": " + trimmedAlias;
    }

    /**
     * Rewrites a managed host as delete-stanza + insert-stanza on freshly
     * parsed text, so the rename case gets the same duplicate refusal as
     * addHost. Renaming while the old alias still has a live session leaves
     * those processes unresolved, which is the same outcome as an external
     * config edit and accepted as such.
     */
    function updateHost(oldAlias, alias, hostName, user, port) {
        const trimmedAlias = String(alias || "").trim();
        const trimmedHost = String(hostName || "").trim();
        const trimmedUser = String(user || "").trim();
        const trimmedPort = String(port || "").trim();
        if (!root.safeAlias(oldAlias) || !root.safeAlias(trimmedAlias))
            return I18n.trFor(root.ns, "Invalid host alias");
        if (!root.safeHostName(trimmedHost))
            return I18n.trFor(root.ns, "Invalid host name");
        if (trimmedUser !== "" && !/^[A-Za-z0-9._-]{1,64}$/.test(trimmedUser))
            return I18n.trFor(root.ns, "Invalid user name");
        if (trimmedPort !== "" && !root.safePort(trimmedPort))
            return I18n.trFor(root.ns, "Port must be between 1 and 65535");
        if (!root.beginOp("write", oldAlias))
            return I18n.trFor(root.ns, "Operation already running for this host");
        const started = root.reloadConfig(() => {
            const fail = message => {
                root.endOp("write", oldAlias);
                ToastService.showError(I18n.trFor(root.ns, "Config update failed"), message);
            };
            const old = root.findHost(oldAlias);
            if (!old || !old.managed) {
                fail(I18n.trFor(root.ns, "Host not found in the managed block"));
                return;
            }
            if (trimmedAlias !== String(oldAlias) && root.findHost(trimmedAlias) !== null) {
                fail(I18n.trFor(root.ns, "A host with this name already exists"));
                return;
            }
            const without = configParser.removeManagedHost(root.mainText, oldAlias);
            if (without === root.mainText) {
                fail(I18n.trFor(root.ns, "Host not found in the managed block"));
                return;
            }
            const stanza = configParser.buildStanza(trimmedAlias, trimmedHost,
                trimmedUser, trimmedPort === "22" ? "" : trimmedPort);
            const newText = configParser.insertManagedHost(without, stanza);
            root.writeConfig(newText, () => {
                root.endOp("write", oldAlias);
                root.reloadConfig(() => root.hostWritten(trimmedAlias));
            }, message => {
                root.endOp("write", oldAlias);
                ToastService.showError(I18n.trFor(root.ns, "Config write failed"), message);
            });
        });
        if (!started) {
            root.endOp("write", oldAlias);
            return I18n.trFor(root.ns, "Config is reloading, try again");
        }
        return I18n.trFor(root.ns, "Host updated") + ": " + trimmedAlias;
    }

    function removeHost(alias) {
        if (!root.safeAlias(alias))
            return I18n.trFor(root.ns, "Invalid host alias");
        const host = root.findHost(alias);
        if (!host)
            return I18n.trFor(root.ns, "Host not found");
        if (!host.managed)
            return I18n.trFor(root.ns,
                "Only managed-block hosts can be removed here; edit your ssh_config for this one");
        if (!root.beginOp("write", alias))
            return I18n.trFor(root.ns, "Operation already running for this host");
        const started = root.reloadConfig(() => {
            const fresh = root.findHost(alias);
            if (!fresh || !fresh.managed) {
                root.endOp("write", alias);
                ToastService.showError(I18n.trFor(root.ns, "Config update failed"),
                    I18n.trFor(root.ns, "Host not found in the managed block"));
                return;
            }
            const newText = configParser.removeManagedHost(root.mainText, alias);
            if (newText === root.mainText) {
                root.endOp("write", alias);
                ToastService.showError(I18n.trFor(root.ns, "Config update failed"),
                    I18n.trFor(root.ns, "Host not found in the managed block"));
                return;
            }
            root.writeConfig(newText, () => {
                root.endOp("write", alias);
                root.reloadConfig(() => root.hostWritten(""));
            }, message => {
                root.endOp("write", alias);
                ToastService.showError(I18n.trFor(root.ns, "Config write failed"), message);
            });
        });
        if (!started) {
            root.endOp("write", alias);
            return I18n.trFor(root.ns, "Config is reloading, try again");
        }
        return I18n.trFor(root.ns, "Host removed") + ": " + alias;
    }

    /**
     * mkdir -p → realpath → cp backup → FileView atomic rewrite → chmod 600.
     * Backup only when the file existed with content. atomicWrites renames a
     * temp file over the target, which would replace a symlink with a plain
     * file, so the write goes to the resolved path instead. ssh refuses
     * too-open configs, so the chmod is not optional. mainText is the text
     * captured by the latest parse.
     */
    function writeConfig(newText, onSuccess, onFailure) {
        const dir = configParser.dirOf(root.configPath);
        root.startJob(["mkdir", "-p", "--", dir], 5000, (ok, message) => {
            if (!ok) {
                onFailure(I18n.trFor(root.ns, "Cannot create") + " " + dir + ": " + message);
                return;
            }
            // -m keeps this working for the first write, when config is absent.
            root.startJob(["realpath", "-m", "--", root.configPath], 5000,
                (resolved, resolvedMessage) => {
                const target = resolved && String(resolvedMessage).trim() !== ""
                    ? String(resolvedMessage).trim() : root.configPath;
                if (!root.configExists || root.mainText === "") {
                    root.writeStep(target, newText, onSuccess, onFailure);
                    return;
                }
                root.startJob(["cp", "-p", "--", target,
                    target + ".sshman.bak"], 5000, (copied, copyMessage) => {
                    if (!copied) {
                        onFailure(I18n.trFor(root.ns, "Backup failed") + ": " + copyMessage);
                        return;
                    }
                    root.writeStep(target, newText, onSuccess, onFailure);
                });
            });
        });
    }

    Component {
        id: writerComp

        FileView {
            id: writer

            property string content: ""

            blockWrites: false
            atomicWrites: true

            Component.onCompleted: setText(content)
        }
    }

    function writeStep(target, newText, onSuccess, onFailure) {
        const fv = writerComp.createObject(root, {
            path: target,
            content: newText
        });
        fv.saved.connect(() => {
            fv.destroy();
            Quickshell.execDetached(["chmod", "600", "--", target]);
            onSuccess();
        });
        fv.saveFailed.connect(() => {
            fv.destroy();
            onFailure(I18n.trFor(root.ns, "Writing %1 was refused").arg(root.configPath));
        });
    }

    // ---- Live sessions -----------------------------------------------------------

    /// -e would make -C a no-op and list the whole table; -C ssh alone selects.
    readonly property var psArgs: ["ps", "-o", "pid=,etimes=,args=", "-C", "ssh"]

    /// OpenSSH short options that consume the next argv token.
    function optionTakesValue(letter) {
        return "b c D E F g i J K L l m O o p Q R s W w".split(" ").includes(letter);
    }

    /**
     * From `ssh <argv...>` find the destination: the first non-option token.
     * Clustered forms like -p2222 carry their value inline and consume no
     * extra token.
     */
    function parseSshTarget(args) {
        const tokens = String(args).split(/\s+/).filter(Boolean);
        for (let i = 1; i < tokens.length; i += 1) {
            const token = tokens[i];
            if (token.startsWith("--"))
                continue;
            if (token.startsWith("-")) {
                if (root.optionTakesValue(token.charAt(1)) && token.length === 2)
                    i += 1;
                continue;
            }
            return token;
        }
        return "";
    }

    function resolveSessionTarget(target) {
        if (target === "")
            return null;
        const direct = root.hosts.find(h => !h.wildcard && h.alias === target);
        if (direct)
            return direct;
        const at = target.indexOf("@");
        const user = at >= 0 ? target.substring(0, at) : "";
        const name = at >= 0 ? target.substring(at + 1) : target;
        return root.hosts.find(h => {
            if (h.wildcard)
                return false;
            if (h.alias === name || h.hostname === name)
                return user === "" || h.user === "" || h.user === user;
            return false;
        }) ?? null;
    }

    function applyPoll(stdout) {
        const sessions = [];
        String(stdout).split("\n").forEach(line => {
            const trimmed = line.trim();
            if (trimmed === "")
                return;
            const fields = trimmed.split(/\s+/);
            if (fields.length < 3)
                return;
            const pid = Number(fields[0]);
            const etime = Number(fields[1]);
            if (!Number.isInteger(pid) || !Number.isInteger(etime))
                return;
            const args = trimmed.substring(fields[0].length + fields[1].length + 2);
            const target = root.parseSshTarget(args);
            const host = root.resolveSessionTarget(target);
            if (!host && !root.settingShowUnresolved)
                return;
            // The ControlPersist helper re-execs as "ssh … sleep N".
            const master = /(^|\s)sleep\s+\d/.test(args);
            sessions.push({
                pid: pid,
                etime: etime,
                target: target,
                alias: host !== null ? host.alias : "",
                kind: master ? "master" : "session",
                connected: host !== null
            });
        });
        sessions.sort((a, b) => a.pid - b.pid);

        const current = {};
        sessions.forEach(session => {
            current[session.pid] = session;
        });
        if (root._sessionBaseline) {
            sessions.forEach(session => {
                if (root._lastSessions[session.pid] === undefined
                    && root.settingNotifyNew && session.kind === "session")
                    root.notify(I18n.trFor(root.ns, "SSH session started"),
                        session.target, "terminal");
            });
            Object.keys(root._lastSessions).forEach(pid => {
                const gone = root._lastSessions[pid];
                if (current[pid] === undefined && root.settingNotifyEnd
                    && gone.kind === "session")
                    root.notify(I18n.trFor(root.ns, "SSH session ended"),
                        gone.target, "terminal_off");
            });
        }
        root._lastSessions = current;
        root._sessionBaseline = true;
        root.sessions = sessions;
        root.lastPollAt = Qt.formatDateTime(new Date(), "HH:mm:ss");
    }

    function pollSessions() {
        Proc.runCommand(root.ns + ".poll", root.psArgs, (stdout, exitCode) => {
            // ps exits 1 when -C matches nothing, which is the common case of
            // "no ssh sessions"; only a nonzero exit with output is a failure.
            if (exitCode !== 0 && String(stdout).trim() !== "") {
                console.warn("[sshMan] ps exited with", exitCode);
                return;
            }
            root.applyPoll(stdout);
        }, 0, 8000, root);
    }

    function killSession(pid) {
        const value = Number(pid);
        if (!Number.isInteger(value) || value <= 1 || value > 4194304)
            return I18n.trFor(root.ns, "Invalid pid");
        root.startJob(["kill", String(value)], 5000, (ok, message) => {
            if (!ok)
                ToastService.showError(I18n.trFor(root.ns, "Kill failed"), message);
            root.pollSessions();
        });
        return I18n.trFor(root.ns, "Terminating session") + " " + value;
    }

    // ---- Display helpers (used by widget and launcher) ------------------------------

    function humanEtime(seconds) {
        const value = Number(seconds);
        if (!Number.isFinite(value) || value < 0)
            return "";
        const h = Math.floor(value / 3600);
        const m = Math.floor(value % 3600 / 60);
        const s = Math.floor(value % 60);
        if (h > 0)
            return `${h}h ${m}m`;
        if (m > 0)
            return `${m}m ${s}s`;
        return `${s}s`;
    }

    function hostSubtitle(host) {
        if (host.wildcard)
            return I18n.trFor(root.ns, "Pattern template");
        const bits = [];
        bits.push((host.user !== "" ? host.user + "@" : "") + host.hostname);
        if (host.port !== "22" && host.port !== "")
            bits.push(":" + host.port);
        if (host.proxyJump !== "")
            bits.push("via " + host.proxyJump);
        return bits.join("");
    }

    // ---- Lifecycle --------------------------------------------------------------

    Timer {
        id: pollTimer

        interval: root.settingPollSeconds * 1000
        running: true
        repeat: true
        onTriggered: root.pollSessions()
    }

    Component.onCompleted: {
        root.loadSettings();
        root.reloadConfig();
        root.pollSessions();
    }

    IpcHandler {
        target: "sshMan"

        function status(): string {
            return JSON.stringify({
                hosts: root.hosts.length,
                sessions: root.sessions.length,
                config: root.configPath,
                configExists: root.configExists,
                parsing: configParser.running,
                lastParse: root.lastParseAt,
                lastPoll: root.lastPollAt,
                ops: root.activeOps,
                tests: root.testResults,
                files: fileManager.engineStatus()
            });
        }

        function list(): string {
            if (root.hosts.length === 0)
                return I18n.trFor(root.ns, "No SSH hosts configured");
            return root.hosts.map(host => {
                const tags = [];
                if (host.wildcard)
                    tags.push(I18n.trFor(root.ns, "template"));
                if (host.managed)
                    tags.push(I18n.trFor(root.ns, "managed"));
                return `${host.alias}  ${root.hostSubtitle(host)}  ${tags.join(" ")}`;
            }).join("\n");
        }

        function live(): string {
            if (root.sessions.length === 0)
                return I18n.trFor(root.ns, "No active SSH sessions");
            return root.sessions.map(session => {
                return `${session.pid}  ${session.target}  `
                    + root.humanEtime(session.etime)
                    + (session.kind === "master" ? "  master" : "");
            }).join("\n");
        }

        function refresh(): string {
            root.reloadConfig();
            root.pollSessions();
            return I18n.trFor(root.ns, "Refreshed");
        }

        function connect(alias: string): string {
            return root.openSession(alias);
        }

        function files(alias: string): string {
            return root.openFiles(alias);
        }

        function test(alias: string): string {
            return root.testHost(alias);
        }

        function add(alias: string, hostName: string, user: string, port: string): string {
            return root.addHost(alias, hostName, user, port);
        }

        function update(oldAlias: string, alias: string, hostName: string,
            user: string, port: string): string {
            return root.updateHost(oldAlias, alias, hostName, user, port);
        }

        function remove(alias: string): string {
            return root.removeHost(alias);
        }

        function kill(pid: int): string {
            return root.killSession(pid);
        }
    }
}
