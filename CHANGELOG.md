# CHANGELOG — inx-dms-plugins

本文件只记 **monorepo 层**的变更（仓库结构、文档、约定、跨插件的重构）。
**各插件的功能演进见它们自己的 CHANGELOG**，此处不重复：
[`ShotRec/CHANGELOG.md`](ShotRec/CHANGELOG.md)、[`UsbDrive/CHANGELOG.md`](UsbDrive/CHANGELOG.md)。
最新在最上方。

## 2026-10-14

- **新增第三个插件 `SshMan/`（id `sshMan`，0.2.0）**：SSH 连接管理，composite 形态
  daemon + dankbar-widget + launcher。解析并托管 `~/.ssh/config`（Include 展开、first-wins
  语义、末尾托管区块），默认终端连接、BatchMode 探活、`ps` 轮询活跃会话、
  双栏文件管理器（本地↔远端 rsync/scp 互传带进度），
  详见 [`SshMan/README.md`](SshMan/README.md)。
- 补上本文件：整合成 monorepo 后只有插件各自的 CHANGELOG，仓库层无台账。

## 2026-10-13

- **建立 monorepo**：原先两个独立项目（`~/coding/dms-shotrec`、`~/coding/dms-usb-manager`）
  整合为 `~/coding/inx-dms-plugins`，布局对齐官方 `dms-plugins`（每插件一个顶层目录 + 自带 `plugin.json`）。
  DMS 侧软链随之改指：
  `~/.config/DankMaterialShell/plugins/{shotrec,usbDrive} -> ~/coding/inx-dms-plugins/{ShotRec,UsbDrive}`。
  当前版本：ShotRec 0.3.2、UsbDrive 0.2.0；插件间互不引用，各自目录自成一体。
- 补齐开源项目配套：`LICENSE`、`README.md`（安装/仓库结构/插件列表）、`CONTRIBUTING.md`（改动约定：行为变更同步 README + 插件 CHANGELOG）。
- `docs/` 官方文档离线存档：修正表格内联代码转换瑕疵后重新抓取。
- `.gitignore` 忽略 QML 编译缓存与本地编辑器产物。