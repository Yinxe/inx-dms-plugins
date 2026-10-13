# inx-dms-plugins

个人 [DankMaterialShell](https://danklinux.com/dankmaterialshell) 插件合集仓库（monorepo），
官方插件仓库 `dms-plugins` 同款布局：每个插件一个顶层目录，各带自己的 `plugin.json`。

## 插件列表

| 目录 | 插件 id | 说明 |
| --- | --- | --- |
| [`ShotRec/`](ShotRec) | `shotrec` | GNOME 风格截图/录屏一体：全屏选区 + 模式选择条 + 顶栏状态图标 + 快捷设置。详见 [ShotRec/README.md](ShotRec/README.md) |
| [`UsbDrive/`](UsbDrive) | `usbDrive` | USB 磁盘监听（插拔/挂载/卸载），系统通知 + DankBar 管理小部件 |

两个插件均为 `type: "composite"`（daemon + dankbar-widget），要求 DMS ≥ 1.6.0。

## 安装

插件运行时目录是 `~/.config/DankMaterialShell/plugins/`，每个插件一个子目录。
本仓库是 monorepo，推荐用符号链接把插件目录挂进去，`git pull` 即可更新：

```bash
git clone https://github.com/<your-name>/inx-dms-plugins ~/repos/inx-dms-plugins
mkdir -p ~/.config/DankMaterialShell/plugins

ln -s ~/repos/inx-dms-plugins/ShotRec ~/.config/DankMaterialShell/plugins/shotrec
ln -s ~/repos/inx-dms-plugins/UsbDrive ~/.config/DankMaterialShell/plugins/usbDrive

dms restart
```

然后在 Settings → Plugins 中 Scan for Plugins 并启用；DankBar 小部件需手动加入栏布局。
不喜欢符号链接的话，直接 `cp -r` 各插件目录效果相同。

## 开发参考

- [`docs/plugins-overview.md`](docs/plugins-overview.md) — 官方插件系统总览
  （类型、安装/注册表/lockfile、翻译），来源 <https://danklinux.com/docs/dankmaterialshell/plugins-overview>
- [`docs/plugin-development.md`](docs/plugin-development.md) — 官方插件开发完整指南
  （plugin.json 清单、组件架构、PluginService API、设置组件、composite/launcher/desktop 插件、翻译），
  来源 <https://danklinux.com/docs/dankmaterialshell/plugin-development>

两份文档抓取于 2026-10-13（对应 DMS 1.6 文档版本），后续开发前先对照最新版官方文档。

## 仓库说明

- 由 `dms-shotrec`、`dms-usb-manager` 两个独立仓库整合而来（整合于 2026-10-13）。
- 各插件目录内保留自己的 `plugin.json`、`translations/`；ShotRec 另有 CHANGELOG。
- 新增插件：在仓库根新建 `<PluginName>/plugin.json` 目录即可，互不依赖。
