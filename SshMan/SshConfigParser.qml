pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

/**
 * Pure-ish ssh_config reader for the sshMan daemon. Walks Include directives
 * (tilde expansion, directory form, trailing-segment globs) breadth-first from
 * the main config, then resolves Host stanzas with OpenSSH's first-wins option
 * semantics: for a concrete alias, every stanza whose pattern list matches it
 * contributes, and the first value seen for an option key is the effective one.
 *
 * Match blocks cannot be evaluated statically, so their options are dropped
 * with a warning. Glob expansion uses `ls -1` argv (never a shell); only the
 * last path segment may contain * or ?.
 */
Item {
    id: root

    readonly property string managedBegin: "# >>> sshMan managed hosts >>>"
    readonly property string managedEnd: "# <<< sshMan managed hosts <<<"

    property bool running: false

    // ---- Small helpers ------------------------------------------------------

    function expandTilde(path) {
        if (path === "~")
            return Quickshell.env("HOME");
        if (path.startsWith("~/"))
            return Quickshell.env("HOME") + path.substring(1);
        return path;
    }

    function dirOf(path) {
        const slash = path.lastIndexOf("/");
        if (slash <= 0)
            return slash === 0 ? "/" : "";
        return path.substring(0, slash);
    }

    /// OpenSSH pattern → anchored case-insensitive RegExp (* ? only).
    function patternToRegExp(pattern) {
        let source = "";
        for (const ch of pattern) {
            if (ch === "*")
                source += ".*";
            else if (ch === "?")
                source += ".";
            else
                source += ch.replace(/[.+^${}()|[\]\\]/g, "\\$&");
        }
        return new RegExp("^" + source + "$", "i");
    }

    function patternMatches(pattern, name) {
        return root.patternToRegExp(pattern).test(name);
    }

    // ---- Synchronous file read ----------------------------------------------

    Component {
        id: syncReaderComp

        FileView {
            blockLoading: true
            blockWrites: true
        }
    }

    /// Returns the file text ("" for an empty file), or null when the read
    /// threw. Missing files and directories typically come back as "", which
    /// the caller disambiguates with the directory probe below.
    function readFileSync(path) {
        let text = null;
        try {
            const fv = syncReaderComp.createObject(root, { path: path });
            text = fv.text();
            fv.destroy();
        } catch (error) {
            console.warn("[sshMan] read failed:", path, error.message);
            text = null;
        }
        return text;
    }

    // ---- Directory probe (argv only, never a shell) -------------------------

    Component {
        id: listJobComp

        Item {
            id: listJob

            property var command: []
            property string output: ""
            signal done(bool ok, string output)

            Process {
                id: listProcess

                command: listJob.command
                running: true

                stdout: SplitParser {
                    splitMarker: "\n"
                    onRead: line => {
                        listJob.output += line + "\n";
                    }
                }
                // Both streams share one buffer: ls explains ENOENT on stderr,
                // and only the failure path reads it back.
                stderr: SplitParser {
                    splitMarker: "\n"
                    onRead: line => {
                        listJob.output += line + "\n";
                    }
                }
                onExited: exitCode => {
                    listJob.done(exitCode === 0, listJob.output);
                }
            }
        }
    }

    /// callback(ok, names): entry names when ls succeeded, ok=false when the
    /// path is missing. For a plain file, ls echoes the queried path back as
    /// the single line, which callers detect to tell "empty file" from
    /// "directory".
    function listDir(path, callback) {
        const job = listJobComp.createObject(root, { command: ["ls", "-1", "--", path] });
        job.done.connect((ok, output) => {
            job.destroy();
            if (!ok) {
                callback(null, []);
                return;
            }
            const names = output.split("\n").filter(line => line.trim() !== "");
            callback(true, names);
        });
    }

    /// OpenSSH ignores included files whose base name starts with "." or ends
    /// with "~"; the same rule keeps our directory walk honest.
    function includableName(name) {
        return !name.startsWith(".") && !name.endsWith("~");
    }

    // ---- Config walk --------------------------------------------------------

    /**
     * Breadth-first queue. Async steps (directory probes) re-enter pump() from
     * their callback, so nested Includes keep their order relative to each
     * other while globs may settle slightly later than a real ssh would.
     */
    function loadConfig(mainPath, callback) {
        if (root.running)
            return;
        root.running = true;
        const state = {
            mainPath: mainPath,
            queue: [mainPath],
            seen: {},
            seenCount: 0,
            entries: [],
            warnings: [],
            callback: callback
        };
        pump(state);
    }

    function pump(state) {
        while (state.queue.length > 0) {
            const path = state.queue.shift();
            if (state.seen[path] === true)
                continue;
            state.seen[path] = true;
            state.seenCount += 1;
            if (state.seenCount > 32) {
                state.warnings.push("Include walk stopped after 32 files (cycle?)");
                finishWalk(state);
                return;
            }

            const base = path.substring(path.lastIndexOf("/") + 1);
            if (base.includes("*") || base.includes("?")) {
                // Glob only allowed on the last segment.
                const dir = path.substring(0, path.lastIndexOf("/")) || "/";
                const matcher = root.patternToRegExp(base);
                root.listDir(dir, (ok, names) => {
                    if (!ok) {
                        state.warnings.push("Include glob has no readable directory: " + dir);
                        pump(state);
                        return;
                    }
                    const hits = names.filter(name => root.includableName(name)
                        && matcher.test(name)).sort()
                        .map(name => dir + "/" + name);
                    state.queue = hits.concat(state.queue);
                    pump(state);
                });
                return;
            }

            const text = root.readFileSync(path);
            if (text !== null && text.trim() !== "") {
                state.entries.push({ path: path, text: text });
                extractIncludes(text, path).forEach(pattern => state.queue.push(pattern));
                continue;
            }

            // "" or throw: could be empty, missing, or a directory. ls settles
            // it: a file echoes the queried path back, a directory lists names.
            root.listDir(path, (ok, names) => {
                if (!ok) {
                    if (path !== state.mainPath)
                        state.warnings.push("Include unreadable: " + path);
                    pump(state);
                    return;
                }
                if (names.length === 1 && names[0] === path) {
                    // Empty regular file.
                    state.entries.push({ path: path, text: "" });
                    pump(state);
                    return;
                }
                const hits = names.filter(root.includableName).sort()
                    .map(name => path + "/" + name);
                state.queue = hits.concat(state.queue);
                pump(state);
            });
            return;
        }
        finishWalk(state);
    }

    /// Include lines → resolved absolute patterns, relative to the file's own
    /// directory, tilde expanded.
    function extractIncludes(text, includingPath) {
        const out = [];
        const baseDir = root.dirOf(includingPath);
        text.split("\n").forEach(line => {
            const match = /^\s*[Ii][Nn][Cc][Ll][Uu][Dd][Ee]\s+(.+)$/.exec(line);
            if (!match)
                return;
            match[1].trim().split(/\s+/).forEach(token => {
                if (token === "")
                    return;
                let path = root.expandTilde(token);
                if (!path.startsWith("/"))
                    path = baseDir + "/" + path;
                out.push(path);
            });
        });
        return out;
    }

    // ---- Stanza parsing ------------------------------------------------------

    /**
     * One Host/Match line opens a stanza; indented (or not) option lines feed
     * it until the next keyword. First value for a key wins even within a
     * stanza, mirroring ssh(5). A Match stanza is collected then discarded.
     */
    function collectStanzas(entries, mainPath) {
        const stanzas = [];
        const warnings = [];
        entries.forEach(entry => {
            let current = null;
            let inManaged = false;
            entry.text.split("\n").forEach(rawLine => {
                const line = rawLine.trim();
                if (line === root.managedBegin) {
                    inManaged = true;
                    return;
                }
                if (line === root.managedEnd) {
                    inManaged = false;
                    return;
                }
                if (line === "" || line.startsWith("#"))
                    return;
                const hostMatch = /^host\s+(.+)$/i.exec(line);
                if (hostMatch) {
                    const patterns = hostMatch[1].trim().split(/\s+/).filter(Boolean);
                    if (patterns.length === 0)
                        return;
                    current = {
                        patterns: patterns,
                        options: {},
                        managed: entry.path === mainPath && inManaged,
                        file: entry.path
                    };
                    stanzas.push(current);
                    return;
                }
                const matchMatch = /^match\s+(.+)$/i.exec(line);
                if (matchMatch) {
                    warnings.push(I18n.trFor("sshMan",
                        "Match block not evaluated statically: %1").arg(matchMatch[1]));
                    current = { patterns: [], options: {}, match: true, file: entry.path, managed: false };
                    stanzas.push(current);
                    return;
                }
                if (current === null || current.match === true)
                    return;
                const option = /^([A-Za-z][A-Za-z0-9_-]*)[ \t]+(.*)$/.exec(line);
                if (option) {
                    const key = option[1].toLowerCase();
                    const value = option[2].trim();
                    if (current.options[key] === undefined && value !== "")
                        current.options[key] = value;
                }
            });
        });
        return { stanzas: stanzas, warnings: warnings };
    }

    /**
     * Concrete aliases come from literal patterns; their effective options
     * merge over every matching stanza in file order, first value wins.
     * Wildcard-only stanzas are surfaced as read-only templates.
     */
    function resolveHosts(stanzas) {
        const byAlias = {};
        const hosts = [];
        stanzas.forEach(stanza => {
            stanza.patterns.forEach(pattern => {
                if (/[*?]/.test(pattern))
                    return;
                if (byAlias[pattern] !== undefined)
                    return;
                const effective = {};
                stanzas.forEach(other => {
                    const hit = other.patterns.some(p => root.patternMatches(p, pattern));
                    if (!hit)
                        return;
                    Object.keys(other.options).forEach(key => {
                        if (effective[key] === undefined)
                            effective[key] = other.options[key];
                    });
                });
                const host = {
                    alias: pattern,
                    hostname: effective.hostname !== undefined ? effective.hostname : pattern,
                    user: effective.user !== undefined ? effective.user : "",
                    port: effective.port !== undefined ? effective.port : "22",
                    proxyJump: effective.proxyjump !== undefined ? effective.proxyjump : "",
                    identity: effective.identityfile !== undefined
                        ? effective.identityfile.split(/\s+/)[0] : "",
                    wildcard: false,
                    managed: stanza.managed === true,
                    file: stanza.file
                };
                byAlias[pattern] = host;
                hosts.push(host);
            });
        });
        stanzas.forEach(stanza => {
            if (!stanza.patterns.every(pattern => /[*?]/.test(pattern)))
                return;
            hosts.push({
                alias: stanza.patterns.join(" "),
                hostname: "",
                user: stanza.options.user !== undefined ? stanza.options.user : "",
                port: stanza.options.port !== undefined ? stanza.options.port : "22",
                proxyJump: stanza.options.proxyjump !== undefined ? stanza.options.proxyjump : "",
                identity: stanza.options.identityfile !== undefined
                    ? stanza.options.identityfile.split(/\s+/)[0] : "",
                wildcard: true,
                managed: stanza.managed === true,
                file: stanza.file
            });
        });
        hosts.sort((a, b) => a.alias.toLowerCase().localeCompare(b.alias.toLowerCase()));
        return hosts;
    }

    function finishWalk(state) {
        const collected = collectStanzas(state.entries, state.mainPath);
        const hosts = resolveHosts(collected.stanzas);
        const mainEntry = state.entries.find(entry => entry.path === state.mainPath);
        root.running = false;
        state.callback({
            hosts: hosts,
            warnings: state.warnings.concat(collected.warnings),
            configExists: mainEntry !== undefined,
            mainText: mainEntry !== undefined ? mainEntry.text : null,
            fileCount: state.entries.length
        });
    }

    // ---- Managed block text surgery ------------------------------------------

    /// Only called with values that already passed the daemon's whitelist.
    function buildStanza(alias, hostName, user, port) {
        let text = "Host " + alias + "\n";
        text += "    HostName " + hostName + "\n";
        if (user !== "")
            text += "    User " + user + "\n";
        if (port !== "")
            text += "    Port " + port + "\n";
        return text;
    }

    function blockHeader() {
        return root.managedBegin + "\n"
            + "# Managed by the DMS sshMan plugin. Edit or remove entries from\n"
            + "# inside this block; text outside it is never touched.\n"
            + root.managedEnd + "\n";
    }

    /**
     * Insert before the end marker, appending a fresh block when the file has
     * none. null input means the config does not exist yet, so the result is
     * only the block — first-wins is why managed stanzas sit at the end.
     */
    function insertManagedHost(text, stanza) {
        const block = stanza.replace(/\n$/, "") + "\n";
        if (text === null)
            return blockHeader().replace(root.managedEnd + "\n", block + root.managedEnd + "\n");
        const end = text.indexOf(root.managedEnd);
        let out;
        if (end >= 0) {
            out = text.substring(0, end) + block + text.substring(end);
        } else {
            const prefix = text.endsWith("\n") || text === "" ? "" : "\n";
            out = text + prefix + "\n" + blockHeader().replace(root.managedEnd + "\n",
                block + root.managedEnd + "\n");
        }
        return out.endsWith("\n") ? out : out + "\n";
    }

    /// Removes the stanza whose Host line lists `alias`, scanning only between
    /// the markers. Returns the same text unchanged when the alias is not
    /// managed, which callers report as an error.
    function removeManagedHost(text, alias) {
        if (text === null)
            return text;
        const lines = text.split("\n");
        const begin = lines.indexOf(root.managedBegin);
        const end = lines.indexOf(root.managedEnd);
        if (begin < 0 || end < 0 || end <= begin)
            return text;
        let start = -1;
        for (let i = begin + 1; i < end; i += 1) {
            const match = /^\s*[Hh][Oo][Ss][Tt]\s+(.+)$/.exec(lines[i]);
            if (match && match[1].trim().split(/\s+/).includes(alias)) {
                start = i;
                break;
            }
        }
        if (start < 0)
            return text;
        let stop = start + 1;
        while (stop < end) {
            const line = lines[stop].trim();
            if (/^host\s/i.test(line) || /^match\s/i.test(line))
                break;
            stop += 1;
        }
        // Drop one directly preceding blank line for tidiness.
        const from = start > begin + 1 && lines[start - 1].trim() === "" ? start - 1 : start;
        const kept = lines.slice(0, from).concat(lines.slice(stop));
        return kept.join("\n");
    }
}
