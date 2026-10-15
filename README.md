# inx-dms-plugins

个人 [DankMaterialShell](https://danklinux.com/dankmaterialshell) 插件合集（monorepo），
沿用官方插件仓库 [`dms-plugins`](https://github.com/AvengeMedia/dms-plugins) 的布局：
每个插件一个顶层目录，各带自己的 `plugin.json`。

## 插件列表

| 目录 | 插件 id | 版本 | 说明 |
| --- | --- | --- | --- |
| [`ShotRec/`](ShotRec) | `shotrec` | 0.4.2 | GNOME 风格截图/录屏一体：全屏选区 + 模式选择条 + 截图标注编辑窗口 + 顶栏状态图标 + 快捷设置。<br>详见 [ShotRec/README.md](ShotRec/README.md) |
| [`UsbDrive/`](UsbDrive) | `usbDrive` | 0.2.0 | USB 磁盘监听（插拔/挂载/卸载），系统通知 + DankBar 管理小部件。<br>详见 [UsbDrive/README.md](UsbDrive/README.md) |
| [`SshMan/`](SshMan) | `sshMan` | 0.2.0 | SSH 连接管理：解析/托管 `~/.ssh/config`，终端连接 + BatchMode 探活 + 活跃会话 + 双栏文件互传，DankBar 小部件 + DankLauncher。<br>详见 [SshMan/README.md](SshMan/README.md) |

三个插件均为 `type: "composite"`（daemon + dankbar-widget，SshMan 另含 launcher），要求 DMS ≥ 1.6.0。

## 安装

插件运行时目录是 `~/.config/DankMaterialShell/plugins/`，每个插件一个子目录。
本仓库是 monorepo，推荐用符号链接把插件目录挂进去，`git pull` 即可更新：

```bash
git clone https://github.com/Yinxe/inx-dms-plugins ~/repos/inx-dms-plugins
mkdir -p ~/.config/DankMaterialShell/plugins

ln -s ~/repos/inx-dms-plugins/ShotRec ~/.config/DankMaterialShell/plugins/shotrec
ln -s ~/repos/inx-dms-plugins/UsbDrive ~/.config/DankMaterialShell/plugins/usbDrive
ln -s ~/repos/inx-dms-plugins/SshMan ~/.config/DankMaterialShell/plugins/sshMan

dms restart
```

然后在 Settings → Plugins 中 Scan for Plugins 并启用；DankBar 小部件需手动加入栏布局。
不喜欢符号链接的话，直接 `cp -r` 各插件目录效果相同。

外部依赖（`wf-recorder` / `udisksctl` 等）见各插件 README 的依赖表。

## 仓库结构

```
.
├── ShotRec/            # 插件：截图/录屏（含 README、CHANGELOG）
├── UsbDrive/           # 插件：USB 设备管理（含 README、CHANGELOG）
├── SshMan/             # 插件：SSH 连接管理（含 README、CHANGELOG）
└── docs/               # 官方插件文档离线存档（非本项目产出，见下）
```

每个插件目录自成一体、互不引用：

```
<Plugin>/
├── plugin.json                    # 清单（id、type、components、依赖、权限）
├── *Daemon.qml / *Widget.qml      # composite 各表面的组件
├── *Settings.qml                  # 设置页
└── translations/zh_CN.json        # I18n.trFor(<id>, ...) 的中文译文
```

## 开发参考

- [`docs/plugins-overview.md`](docs/plugins-overview.md) — 官方插件系统总览
  （类型、安装/注册表/lockfile、翻译），来源 <https://danklinux.com/docs/dankmaterialshell/plugins-overview>
- [`docs/plugin-development.md`](docs/plugin-development.md) — 官方插件开发完整指南
  （plugin.json 清单、组件架构、PluginService API、设置组件、composite/launcher/desktop 插件、翻译），
  来源 <https://danklinux.com/docs/dankmaterialshell/plugin-development>

这两份是官方文档的**离线存档**，抓取于 2026-10-13（对应 DMS 1.6 文档版本），版权归 AvengeMedia 上游所有，
后续开发前请先对照在线最新版。开发流程、代码约定与 PR 要求见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。

## 许可

本仓库原创代码以 [MIT](LICENSE) 发布；`docs/` 下的官方文档存档不在此许可范围内（见上节说明）。
