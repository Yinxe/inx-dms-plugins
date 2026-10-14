pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services

/**
 * DankLauncher surface for sshMan. The effective trigger is read by
 * PluginService from settings with the manifest value as fallback; the local
 * load below only mirrors it back into the settings page field. Items come
 * straight off the daemon instance, so a config rescan is reflected the next
 * time the launcher asks for results.
 */
Item {
    id: root

    property var pluginService: null
    property string pluginId: "sshMan"
    property string trigger: "!ssh"

    signal itemsChanged

    readonly property var daemon: root.pluginService
        ? root.pluginService.pluginDaemonInstances["sshMan"] ?? null : null

    function matches(host, query) {
        const text = query.toLowerCase();
        if (host.alias.toLowerCase().includes(text))
            return true;
        if (host.hostname.toLowerCase().includes(text))
            return true;
        if (host.user !== "" && host.user.toLowerCase().includes(text))
            return true;
        if (host.port !== "" && host.port !== "22" && host.port.includes(text))
            return true;
        return false;
    }

    function getItems(query) {
        if (!root.daemon || !query || query.trim().length === 0)
            return [];
        const text = query.trim();
        const items = [];
        root.daemon.hosts.forEach(host => {
            if (host.wildcard || !root.matches(host, text))
                return;
            const bits = [];
            if (host.user !== "")
                bits.push(host.user + "@");
            bits.push(host.hostname);
            if (host.port !== "22" && host.port !== "")
                bits.push(":" + host.port);
            const comment = bits.join("") + (host.managed ? " · managed" : "");
            items.push({
                name: host.alias,
                icon: "material:terminal",
                comment: comment,
                action: "connect:" + host.alias,
                categories: ["SSH"],
                keywords: [host.hostname, host.user, "ssh"]
            });
        });
        return items;
    }

    function executeItem(item) {
        if (!item?.action || !item.action.startsWith("connect:"))
            return;
        const alias = item.action.substring("connect:".length);
        if (!root.daemon) {
            ToastService.showError(I18n.trFor("sshMan", "SSH Manager"),
                I18n.trFor("sshMan", "Daemon is not running"));
            return;
        }
        const message = root.daemon.openSession(alias);
        if (message !== "")
            ToastService.showInfo(I18n.trFor("sshMan", "SSH Manager"), message);
    }

    function getContextMenuActions(item) {
        if (!item?.action?.startsWith("connect:") || !root.daemon)
            return [];
        const alias = item.action.substring("connect:".length);
        const host = root.daemon.findHost(alias);
        const actions = [
            {
                icon: "content_copy",
                text: I18n.trFor(root.pluginId, "Copy ssh command"),
                action: () => {
                    root.daemon.copyCommand(alias);
                }
            },
            {
                icon: "network_check",
                text: I18n.trFor(root.pluginId, "Test connection"),
                action: () => {
                    root.daemon.testHost(alias);
                }
            }
        ];
        if (host && host.managed) {
            actions.push({
                icon: "delete",
                text: I18n.trFor(root.pluginId, "Remove host"),
                action: () => {
                    const message = root.daemon.removeHost(alias);
                    ToastService.showInfo(I18n.trFor(root.pluginId, "SSH Manager"), message);
                    root.itemsChanged();
                }
            });
        }
        return actions;
    }

    Component.onCompleted: {
        if (!root.pluginService)
            return;
        root.trigger = root.pluginService.loadPluginData(root.pluginId, "trigger", "!ssh");
    }
}
