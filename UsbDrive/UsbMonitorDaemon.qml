pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

/**
 * usbDrive daemon. Watches udev block events, rebuilds the removable-drive
 * list from lsblk (plus df for byte-level usage), classifies plug/unplug and
 * mount/unmount, runs mount/unmount/eject through udisksctl with per-job error
 * reporting, optionally auto-mounts the data partition of a freshly plugged
 * stick, and publishes events on the unified freedesktop notification channel
 * (DMS notification center). The bar widget reads this instance through
 * PluginService.
 */
PluginComponent {
    id: root

    readonly property string ns: "usbDrive"

    /// [{name, path, vendor, model, serial, size, tran, rm, mountedCount, partitions}]
    property var drives: []
    property string lastScanAt: ""
    property bool monitorAvailable: false

    /// ["<kind>:<device>", ...] for every udisksctl job in flight. Reassigned
    /// rather than mutated so bar delegates can bind on it and get invalidated
    /// when it changes.
    property var activeJobs: []

    /// Partition names whose file manager should open as soon as a scan lands
    /// the mountpoint, for the "open an unmounted volume" flow.
    property var pendingOpen: ({})

    /// argv prefix of the system default file manager, resolved once at startup.
    /// Empty means nothing trustworthy claims inode/directory, so the open
    /// action falls back to the default terminal.
    property var fileManagerArgv: []

    // Settings mirrored from pluginData so imperative code has plain types.
    property bool settingNotifyPlug: true
    property bool settingNotifyMount: false
    property bool settingAutoMount: false
    property int settingScanDebounce: 800

    // Diff baselines for change classification.
    property var _lastDriveNames: ({})
    property var _lastPartitionMounts: ({})
    property bool _baselined: false
    property bool _intentionalStop: false

    // No -d: it suppresses children, so partitions would never be listed.
    // No -p: NAME stays the bare device node, which the action helpers and
    // safeName() expect; PATH carries the full /dev node.
    // FSUSE% is the filesystem's own usage, and null while unmounted.
    readonly property var lsblkArgs: [
        "lsblk", "-b", "-J", "-o",
        "NAME,PATH,TYPE,VENDOR,MODEL,SERIAL,SIZE,FSTYPE,LABEL,MOUNTPOINT,RM,TRAN,FSUSE%"
    ]

    // df prints one column per device without a mountpoint column, so no
    // whitespace in a volume label can shift the fields we parse.
    readonly property var dfArgs: ["df", "-B1", "--output=source,size,used,avail,pcent"]

    /// One default per key, shared with the settings page. Keeping the
    /// fallback inline in each reader is how notifyMountEvents drifted to
    /// "true in code, false on the page".
    function settingBool(key, fallback) {
        const value = root.pluginData[key];
        return value === undefined ? fallback : value === true;
    }

    function loadSettings() {
        root.settingNotifyPlug = root.settingBool("notifyPlugEvents", true);
        root.settingNotifyMount = root.settingBool("notifyMountEvents", false);
        root.settingAutoMount = root.settingBool("autoMount", false);
        const debounce = Number(root.pluginData.scanDebounceMs);
        root.settingScanDebounce = Number.isFinite(debounce) && debounce >= 100
            ? debounce : 800;
    }

    onPluginDataChanged: root.loadSettings()

    // ---- Unified system notification channel -------------------------------

    /**
     * Posts through DMS' own notify CLI, which lands in the notification
     * center and keeps the plugin off raw GVariant syntax: volume labels are
     * user-controlled text, and a quote in one would break a hand-built
     * a{sv} dictionary. argv only, never a shell.
     */
    function notify(title, body, icon) {
        Quickshell.execDetached([
            "dms", "notify", title, body,
            "--icon", icon,
            "--app", "USB Drive"
        ]);
    }

    // ---- Formatting --------------------------------------------------------

    function humanSize(bytes) {
        const value = Number(bytes);
        if (!Number.isFinite(value) || value < 0)
            return "";
        if (value === 0)
            return "0 B";
        const units = ["B", "KB", "MB", "GB", "TB"];
        let size = value;
        let unit = 0;
        while (size >= 1024 && unit < units.length - 1) {
            size /= 1024;
            unit += 1;
        }
        return `${size.toFixed(size >= 100 || unit === 0 ? 0 : 1)} ${units[unit]}`;
    }

    function basename(path) {
        if (!path)
            return "";
        const parts = String(path).split("/");
        return parts[parts.length - 1] || "";
    }

    function driveTitle(drive) {
        return drive.model !== "" ? drive.model : (drive.name !== "" ? drive.name : "USB");
    }

    function driveSubtitle(drive) {
        const bits = [];
        if (drive.vendor !== "")
            bits.push(drive.vendor);
        const size = root.humanSize(drive.size);
        if (size !== "")
            bits.push(size);
        if (drive.serial !== "")
            bits.push("#" + drive.serial);
        bits.push(drive.rm
            ? I18n.trFor(root.ns, "Removable")
            : I18n.trFor(root.ns, "Fixed"));
        return bits.join(" · ");
    }

    function partitionName(partition) {
        if (partition.label !== "")
            return partition.label;
        const mounted = root.basename(partition.mountpoint);
        if (mounted !== "")
            return mounted;
        return partition.name;
    }

    // ---- Scanning ----------------------------------------------------------

    /**
     * lsblk repeats inherited columns on children, so matching the parent disk
     * is enough to keep its partitions.
     */
    function matchesDevice(device) {
        const tran = String(device.tran || "").toLowerCase();
        const mode = String(root.pluginData.matchMode || "any");
        if (mode === "removable")
            return device.rm === true;
        if (mode === "usb")
            return tran === "usb";
        // "any": union of both, since SD readers and some enclosures report
        // rm without tran=usb, and thumb drives on hubs do the reverse.
        return tran === "usb" || device.rm === true;
    }

    function usagePercentOf(raw) {
        // lsblk reports FSUSE% as a string like "82%", and as null whenever the
        // volume is not mounted. -1 keeps "no data" distinct from "empty".
        const text = String(raw === undefined || raw === null ? "" : raw).replace("%", "");
        const value = Number(text);
        return Number.isFinite(value) && text !== "" ? value : -1;
    }

    /// Mounted volumes are what the usage figures can mean anything for, so the
    /// drive-level totals are the sum of the mounted partitions only.
    function summarize(drive) {
        const mounted = drive.partitions.filter(p => p.mountpoint !== "");
        drive.partitionCount = drive.partitions.length;
        drive.mountedCount = mounted.length;
        drive.totalBytes = 0;
        drive.usedBytes = 0;
        drive.availBytes = 0;
        mounted.forEach(partition => {
            drive.totalBytes += partition.totalBytes || 0;
            drive.usedBytes += partition.usedBytes || 0;
            drive.availBytes += partition.availBytes || 0;
        });
        return drive;
    }

    function parseDrives(payload) {
        let devices;
        try {
            devices = JSON.parse(payload).blockdevices;
        } catch (e) {
            console.warn("[usbDrive] bad lsblk output:", e.message);
            return [];
        }
        if (!Array.isArray(devices))
            return [];

        const drives = [];
        devices.forEach(disk => {
            const name = String(disk.name || "");
            if (name === "" || disk.type !== "disk")
                return;
            if (!root.matchesDevice(disk))
                return;
            const partitions = [];
            (disk.children || []).forEach(partition => {
                const pname = String(partition.name || "");
                if (pname === "" || partition.type !== "part")
                    return;
                partitions.push({
                    name: pname,
                    driveName: name,
                    path: partition.path || "/dev/" + pname,
                    fstype: String(partition.fstype || ""),
                    label: String(partition.label || ""),
                    mountpoint: String(partition.mountpoint || ""),
                    size: Number(partition.size || 0),
                    usagePercent: root.usagePercentOf(partition["fsuse%"]),
                    totalBytes: 0,
                    usedBytes: 0,
                    availBytes: 0
                });
            });
            if (disk.fstype) {
                // Superfloppy: filesystem on the whole disk, no partition table.
                partitions.unshift({
                    name: name,
                    driveName: name,
                    path: disk.path || "/dev/" + name,
                    fstype: String(disk.fstype),
                    label: String(disk.label || ""),
                    mountpoint: String(disk.mountpoint || ""),
                    size: Number(disk.size || 0),
                    usagePercent: root.usagePercentOf(disk["fsuse%"]),
                    totalBytes: 0,
                    usedBytes: 0,
                    availBytes: 0
                });
            }
            drives.push(root.summarize({
                name: name,
                path: disk.path || "/dev/" + name,
                vendor: String(disk.vendor || ""),
                model: String(disk.model || ""),
                serial: String(disk.serial || ""),
                size: Number(disk.size || 0),
                tran: String(disk.tran || ""),
                rm: disk.rm === true,
                partitions: partitions
            }));
        });
        drives.sort((a, b) => a.name.localeCompare(b.name));
        return drives;
    }

    function reportChanges(changes) {
        changes.plugged.forEach(drive => {
            if (root.settingNotifyPlug)
                root.notify(I18n.trFor(root.ns, "USB drive connected"),
                    `${root.driveTitle(drive)}  ${root.driveSubtitle(drive)}`, "usb");
        });
        changes.removed.forEach(drive => {
            if (root.settingNotifyPlug)
                root.notify(I18n.trFor(root.ns, "USB drive removed"),
                    root.driveTitle(drive), "usb_off");
        });
        changes.mounted.forEach(event => {
            if (root.settingNotifyMount)
                root.notify(I18n.trFor(root.ns, "Volume mounted"),
                    `${root.partitionName(event.partition)}  →  ${event.partition.mountpoint}`, "usb");
        });
        changes.unmounted.forEach(event => {
            if (root.settingNotifyMount)
                root.notify(I18n.trFor(root.ns, "Volume unmounted"),
                    root.partitionName(event.partition), "eject");
        });
    }

    function applyScan(payload) {
        const currentDrives = root.parseDrives(payload);
        const baseline = !root._baselined;
        const changes = {
            plugged: [], removed: [], mounted: [], unmounted: []
        };

        const currentNames = {};
        const currentMounts = {};
        currentDrives.forEach(drive => {
            currentNames[drive.name] = true;
            drive.partitions.forEach(partition => {
                currentMounts[partition.name] = partition.mountpoint;
            });
        });

        if (!baseline) {
            root.drives.forEach(drive => {
                if (currentNames[drive.name] === undefined)
                    changes.removed.push(drive);
            });
            currentDrives.forEach(drive => {
                if (root._lastDriveNames[drive.name] === undefined) {
                    changes.plugged.push(drive);
                    return;
                }
                drive.partitions.forEach(partition => {
                    const was = root._lastPartitionMounts[partition.name] || "";
                    if (was === "" && partition.mountpoint !== "")
                        changes.mounted.push({drive: drive, partition: partition});
                    else if (was !== "" && partition.mountpoint === "")
                        changes.unmounted.push({drive: drive, partition: partition});
                });
            });
            // A volume that disappeared with a mountpoint, or vanished with the
            // whole drive, counts as an unmount only when it really was mounted.
            root.drives.forEach(drive => {
                if (currentNames[drive.name] !== undefined)
                    return;
                drive.partitions.forEach(partition => {
                    if (partition.mountpoint !== "")
                        changes.unmounted.push({drive: drive, partition: partition});
                });
            });
            root.reportChanges(changes);
        }

        root.drives = currentDrives;
        root._lastDriveNames = currentNames;
        root._lastPartitionMounts = currentMounts;
        root._baselined = true;
        root.lastScanAt = Qt.formatDateTime(new Date(), "HH:mm:ss");
        root.fetchUsage(currentDrives);
        root.flushPendingOpen();
        if (!baseline && changes.plugged.length > 0 && root.settingAutoMount)
            autoMountTimer.restart();
    }

    /**
     * lsblk already gives the filesystem percentage; byte totals only come from
     * df, so mounted volumes share one batched call instead of one per volume.
     * Result is merged into a rebuilt array because mutating objects in place
     * would not invalidate the bar widget's bindings.
     */
    function fetchUsage(drives) {
        const devices = [];
        drives.forEach(drive => {
            drive.partitions.forEach(partition => {
                if (partition.mountpoint !== "")
                    devices.push(partition.path);
            });
        });
        if (devices.length === 0)
            return;
        Proc.runCommand(root.ns + ".df", root.dfArgs.concat(devices), (stdout, exitCode) => {
            if (exitCode !== 0) {
                console.warn("[usbDrive] df exited with", exitCode);
                return;
            }
            const bySource = {};
            // First line is the header, and its wording follows the locale.
            String(stdout).split("\n").slice(1).forEach(line => {
                const fields = line.trim().split(/\s+/);
                if (fields.length < 5)
                    return;
                bySource[fields[0]] = {
                    totalBytes: Number(fields[1]),
                    usedBytes: Number(fields[2]),
                    availBytes: Number(fields[3])
                };
            });
            const merged = drive => root.summarize(Object.assign({
                    }, drive, {
                        partitions: drive.partitions.map(partition => {
                            const hit = partition.mountpoint !== "" ? bySource[partition.path] : undefined;
                            return hit ? Object.assign({}, partition, hit) : partition;
                        })
                    }));
            root.drives = root.drives.map(merged);
        }, 0);
    }

    /// Single-shot: an open requested before the mount is fulfilled by the first
    /// scan that reports a mountpoint, and dropped otherwise. The volume is
    /// mounted either way, so a second click opens it immediately.
    function flushPendingOpen() {
        const names = Object.keys(root.pendingOpen);
        if (names.length === 0)
            return;
        root.pendingOpen = {};
        names.forEach(name => {
            const partition = root.findPartition(name);
            if (partition && partition.mountpoint !== "")
                root.openPath(partition.mountpoint);
        });
    }

    function rescan() {
        Proc.runCommand(root.ns + ".scan", root.lsblkArgs, (stdout, exitCode) => {
            if (exitCode !== 0) {
                console.warn("[usbDrive] lsblk exited with", exitCode);
                return;
            }
            root.applyScan(stdout);
        }, 0);
    }

    function scheduleScan(reason) {
        if (reason === "change")
            root.rescan();
        else
            scanTimer.restart();
    }

    function findDrive(driveName) {
        return root.drives.find(drive => drive.name === String(driveName)) ?? null;
    }

    function findPartition(partitionName) {
        const wanted = String(partitionName);
        for (const drive of root.drives) {
            const hit = drive.partitions.find(partition => partition.name === wanted);
            if (hit)
                return hit;
        }
        return null;
    }

    function jobActive(kind, deviceName) {
        return root.activeJobs.indexOf(kind + ":" + deviceName) >= 0;
    }

    Timer {
        id: scanTimer
        interval: root.settingScanDebounce
        onTriggered: root.rescan()
    }

    /**
     * usb_storage takes a second or so to run the SCSI scan after the plug
     * event, so the partition table is often still invisible the moment udev
     * says "add". Mounting off the plugged snapshot would miss; the timer fires
     * after that settles and re-reads the tree from scratch.
     */
    Timer {
        id: autoMountTimer
        interval: 1800
        onTriggered: root.autoMountTick()
    }

    // ---- udev monitor ------------------------------------------------------

    // `running` is deliberately not declared: a `running: <binding>` here plus
    // the imperative `running = true` in reconnectTimer would fight each other,
    // the first write silently killing the binding. Every lifecycle change is
    // an explicit write instead (dependencyCheck, reconnectTimer, destruction).
    Process {
        id: udevMonitor
        command: ["udevadm", "monitor", "--udev", "--subsystem-match=block"]

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                // "UDEV  [1234.567890] change  /devices/.../block/sdb"
                if (!line.startsWith("UDEV") || line.indexOf("/block/") < 0)
                    return;
                const kind = line.includes("] remove") ? "remove"
                    : (line.includes("] change") ? "change" : "add");
                root.scheduleScan(kind);
            }
        }

        onExited: {
            if (!root._intentionalStop && root.monitorAvailable)
                reconnectTimer.restart();
        }
    }

    Timer {
        id: reconnectTimer
        interval: 3000
        onTriggered: {
            udevMonitor.running = true;
            root.rescan();
        }
    }

    Process {
        id: dependencyCheck
        command: ["sh", "-c", "command -v udevadm >/dev/null && command -v lsblk >/dev/null"]
        onExited: exitCode => {
            root.monitorAvailable = (exitCode === 0);
            if (exitCode !== 0)
                console.warn("[usbDrive] udevadm/lsblk unavailable, falling back to manual scan");
            else
                udevMonitor.running = true;
            root.rescan();
        }
    }

    // ---- Device actions ----------------------------------------------------

    /// udisksctl gets argv, never a shell, so device names cannot inject.
    function safeName(name) {
        return /^[A-Za-z0-9._-]+$/.test(String(name || ""));
    }

    function mountedPartitions(drive) {
        return drive.partitions.filter(p => p.mountpoint !== "");
    }

    /// The data volume of a stick is its largest mountable partition, which is
    /// what tells it apart from the EFI and recovery slivers on installer media.
    function dataCandidates(drive) {
        return drive.partitions.filter(p => p.fstype !== "" && p.fstype !== "swap");
    }

    function largest(list) {
        if (list.length === 0)
            return null;
        return list.reduce((best, item) => item.size > best.size ? item : best);
    }

    function primaryDataPartition(drive) {
        return root.largest(root.dataCandidates(drive));
    }

    function failureTitle(kind) {
        if (kind === "mount")
            return I18n.trFor(root.ns, "Mount failed");
        if (kind === "unmount")
            return I18n.trFor(root.ns, "Unmount failed");
        if (kind === "eject")
            return I18n.trFor(root.ns, "Eject failed");
        return I18n.trFor(root.ns, "Action failed");
    }

    /**
     * udisksctl puts its reason on stderr — "Device is busy" among them — and
     * that is the only honest busy report there is, so the text goes into the
     * toast as-is instead of being guessed from /sys holders.
     */
    function reportFailure(kind, message) {
        ToastService.showError(root.failureTitle(kind),
            message !== "" ? message : I18n.trFor(root.ns, "udisksctl reported an error"));
    }

    /**
     * Runs one udisksctl call and reports how it went. Exactly one job per
     * kind+device may be in flight, which is what stops a double click from
     * queueing two power-offs for the same stick.
     */
    function startAction(kind, deviceName, command, onSuccess, onFailure) {
        if (!root.safeName(deviceName)) {
            root.reportFailure(kind, I18n.trFor(root.ns, "Invalid device name"));
            return false;
        }
        const key = kind + ":" + deviceName;
        if (root.activeJobs.indexOf(key) >= 0)
            return false;
        root.activeJobs = root.activeJobs.concat([key]);
        const job = actionJobComp.createObject(root, {command: command});
        job.finished.connect((ok, message) => {
            root.activeJobs = root.activeJobs.filter(entry => entry !== key);
            root.scheduleScan("action");
            if (ok) {
                if (onSuccess)
                    onSuccess(message);
            } else if (onFailure) {
                onFailure(message);
            } else {
                root.reportFailure(kind, message);
            }
            job.destroy();
        });
        return true;
    }

    /**
     * One throwaway Process per action. Proc.runCommand would be the shortcut,
     * but it swallows stderr — where udisksctl explains a busy device — and a
     * second call on the same id overwrites the first callback, so a slow
     * unmount could hand its result to an unrelated mount.
     */
    Component {
        id: actionJobComp

        Item {
            id: actionJob

            property var command: []
            property string output: ""

            /// ok=false comes with whatever the tool said about why.
            signal finished(bool ok, string message)

            Process {
                id: actionProcess

                command: actionJob.command
                running: true

                // Both streams share one buffer; only failures read it, and
                // stdout ("Mounted /dev/sdb1 at …") is locale-translated.
                stdout: SplitParser {
                    splitMarker: "\n"
                    onRead: line => {
                        actionJob.output += line + "\n";
                    }
                }
                stderr: SplitParser {
                    splitMarker: "\n"
                    onRead: line => {
                        actionJob.output += line + "\n";
                    }
                }
                onExited: exitCode => {
                    actionJob.finished(exitCode === 0, actionJob.output.trim());
                }
            }
        }
    }

    function mountPartition(partitionName) {
        const partition = root.findPartition(partitionName);
        if (!partition)
            return I18n.trFor(root.ns, "Partition not found");
        if (partition.mountpoint !== "")
            return I18n.trFor(root.ns, "Already mounted");
        root.startAction("mount", partitionName, ["udisksctl", "mount", "-b", partition.path], null, null);
        return I18n.trFor(root.ns, "Mounting") + " " + partitionName;
    }

    function unmountPartition(partitionName) {
        const partition = root.findPartition(partitionName);
        if (!partition)
            return I18n.trFor(root.ns, "Partition not found");
        if (partition.mountpoint === "")
            return I18n.trFor(root.ns, "Not mounted");
        root.startAction("unmount", partitionName, ["udisksctl", "unmount", "-b", partition.path], null, null);
        return I18n.trFor(root.ns, "Unmounting") + " " + partitionName;
    }

    /**
     * udisksctl power-off does not unmount for you — the atomic form exists
     * only on the D-Bus method — so a safe eject is a chain: unmount each volume
     * in turn, stop dead on the first failure, because a busy volume means data
     * still in flight and that is precisely when power must not be cut, then
     * power off. Paths and volumes are captured up front, so a stick pulled mid
     * chain cannot leave us acting on a recycled device node.
     */
    function ejectDrive(driveName) {
        const drive = root.findDrive(driveName);
        if (!drive || !root.safeName(driveName))
            return I18n.trFor(root.ns, "Drive not found");
        if (root.jobActive("eject", driveName))
            return I18n.trFor(root.ns, "Eject already running");
        root.ejectStep(drive.path, drive.name, root.mountedPartitions(drive));
        return I18n.trFor(root.ns, "Ejecting") + " " + drive.name;
    }

    function ejectStep(drivePath, driveName, remaining) {
        if (remaining.length === 0) {
            root.startAction("eject", driveName, ["udisksctl", "power-off", "-b", drivePath], null, null);
            return;
        }
        const volume = remaining[0];
        const started = root.startAction("unmount", volume.name,
            ["udisksctl", "unmount", "-b", volume.path],
            () => root.ejectStep(drivePath, driveName, remaining.slice(1)),
            message => root.reportFailure("unmount", message));
        if (!started)
            root.reportFailure("eject", I18n.trFor(root.ns, "Another action is still running"));
    }

    /// Candidate locations of a desktop entry, argv built without a shell.
    function desktopEntryPaths(id) {
        const dataHome = String(Quickshell.env("XDG_DATA_HOME")
            || (Quickshell.env("HOME") + "/.local/share"));
        const dirs = String(Quickshell.env("XDG_DATA_DIRS")
            || "/usr/local/share:/usr/share").split(":");
        const paths = [dataHome + "/applications/" + id];
        dirs.forEach(dir => {
            if (dir !== "")
                paths.push(dir + "/applications/" + id);
        });
        return paths;
    }

    /// Exec is taken apart into argv and the field codes dropped, so the mount
    /// point can be appended as one argument. Quotes are stripped rather than
    /// honoured: a quoted Exec token is a desktop-file mistake, not a case to
    /// support by launching it through a shell.
    function applyDesktopEntry(text) {
        let execLine = "";
        let categories = "";
        text.split("\n").forEach(line => {
            if (execLine === "" && line.startsWith("Exec="))
                execLine = line.substring(5);
            else if (categories === "" && line.startsWith("Categories="))
                categories = line.substring(11);
        });
        const isFileManager = categories.split(";").some(entry => {
            return entry.toLowerCase() === "filemanager" || entry.toLowerCase() === "systemfilemanager";
        });
        if (!isFileManager)
            return;
        const argv = execLine.replace(/%[fFuUdDnNickvm]/g, "").replace(/"/g, "")
            .split(/\s+/).filter(token => token !== "");
        if (argv.length > 0)
            root.fileManagerArgv = argv;
    }

    /// The handler for inode/directory is not necessarily a file manager — a
    /// disk analyzer can claim it — so the entry is read and only accepted when
    /// its own Categories say it is one.
    function resolveFileManager() {
        Proc.runCommand(root.ns + ".fmquery", ["xdg-mime", "query", "default", "inode/directory"], (stdout, exitCode) => {
            const id = String(stdout).trim().split(/\s+/)[0];
            if (exitCode !== 0 || !/^[A-Za-z0-9._+-]+\.desktop$/.test(id)) {
                console.warn("[usbDrive] no default handler for inode/directory");
                return;
            }
            Proc.runCommand(root.ns + ".fmentry",
                ["grep", "-h", "-E", "^(Exec|Categories)="].concat(root.desktopEntryPaths(id)),
                (entryText) => {
                    if (entryText.trim() === "") {                        console.warn("[usbDrive] desktop entry unreadable:", id);
                        return;
                    }
                    root.applyDesktopEntry(entryText);
                }, 0);
        }, 0);
    }

    /// DMS resolves the terminal from its own setting first, then $TERMINAL.
    function terminalCommand() {
        try {
            const resolved = String(SessionData.resolveTerminal() || "");
            if (resolved !== "")
                return resolved;
        } catch (error) {
            console.warn("[usbDrive] SessionData not reachable, using $TERMINAL");
        }
        return String(Quickshell.env("TERMINAL") || "");
    }

    /// A configured file manager may carry arguments, and the value is still
    /// split into argv rather than handed to a shell.
    function openPath(path) {
        const configured = String(root.pluginData.fileManagerApp || "").trim();
        if (configured !== "") {
            Quickshell.execDetached(configured.split(/\s+/).filter(Boolean).concat([path]));
            return;
        }
        if (root.fileManagerArgv.length > 0) {
            Quickshell.execDetached(root.fileManagerArgv.concat([path]));
            return;
        }
        const terminal = root.terminalCommand();
        if (terminal !== "") {
            Quickshell.execDetached({
                command: [terminal],
                workingDirectory: path
            });
            return;
        }
        root.reportFailure("open", I18n.trFor(root.ns, "No file manager or terminal is available"));
    }

    /// Opening a volume that is not mounted mounts it first, and browses it only
    /// once the mount actually landed.
    function requestOpenPartition(partitionName) {
        const partition = root.findPartition(partitionName);
        if (!partition)
            return I18n.trFor(root.ns, "Partition not found");
        if (partition.mountpoint !== "") {
            root.openPath(partition.mountpoint);
            return I18n.trFor(root.ns, "Opening") + " " + partition.mountpoint;
        }
        if (partition.fstype === "")
            return I18n.trFor(root.ns, "No supported filesystem");
        const started = root.startAction("mount", partitionName,
            ["udisksctl", "mount", "-b", partition.path],
            () => {
                // The mountpoint is lsblk's to report, not udisksctl's stdout to
                // parse, so request a scan and open from it.
                root.pendingOpen[partitionName] = true;
                root.rescan();
            },
            message => root.reportFailure("mount", message));
        if (!started)
            return I18n.trFor(root.ns, "Already working on this device");
        return I18n.trFor(root.ns, "Mounting") + " " + partitionName;
    }

    function openDrive(driveName) {
        const drive = root.findDrive(driveName);
        if (!drive)
            return I18n.trFor(root.ns, "Drive not found");
        const target = root.primaryDataPartition(drive) ?? root.mountedPartitions(drive)[0] ?? null;
        if (!target)
            return I18n.trFor(root.ns, "Nothing to open");
        return root.requestOpenPartition(target.name);
    }

    /// Only ever reached with auto-mount enabled, and never on the plugged
    /// snapshot: the partition table is still being built when udev reports the
    /// add, so this re-reads the tree and mounts what it finds.
    function autoMountTick() {
        Proc.runCommand(root.ns + ".automount", root.lsblkArgs, (stdout, exitCode) => {
            if (exitCode !== 0)
                return;
            root.parseDrives(stdout).forEach(drive => {
                const partition = root.primaryDataPartition(drive);
                // udisks or root may already have beaten us to it.
                if (!partition || partition.mountpoint !== "")
                    return;
                root.startAction("mount", partition.name,
                    ["udisksctl", "mount", "-b", partition.path], null, null);
            });
        }, 0);
    }

    // ---- Lifecycle ---------------------------------------------------------

    Component.onCompleted: {
        root.loadSettings();
        root.resolveFileManager();
        dependencyCheck.running = true;
    }

    Component.onDestruction: {
        root._intentionalStop = true;
        udevMonitor.running = false;
    }

    IpcHandler {
        target: "usbDrive"

        function status(): string {
            return JSON.stringify({
                drives: root.drives.length,
                monitor: root.monitorAvailable,
                lastScan: root.lastScanAt,
                autoMount: root.settingAutoMount,
                jobs: root.activeJobs,
                fileManager: root.fileManagerArgv.join(" ")
            });
        }

        function list(): string {
            if (root.drives.length === 0)
                return I18n.trFor(root.ns, "No USB drives detected");
            return root.drives.map(drive => {
                const state = drive.mountedCount > 0
                    ? I18n.trFor(root.ns, "mounted") : I18n.trFor(root.ns, "unmounted");
                return `${drive.name}  ${root.driveTitle(drive)}  ${root.driveSubtitle(drive)}  ${state}`;
            }).join("\n");
        }

        function rescan(): string {
            root.rescan();
            return I18n.trFor(root.ns, "Rescanned");
        }

        function eject(name: string): string {
            return root.ejectDrive(name);
        }

        function mount(name: string): string {
            return root.mountPartition(name);
        }

        function unmount(name: string): string {
            return root.unmountPartition(name);
        }

        function open(name: string): string {
            return root.findDrive(name) ? root.openDrive(name) : root.requestOpenPartition(name);
        }
    }
}
