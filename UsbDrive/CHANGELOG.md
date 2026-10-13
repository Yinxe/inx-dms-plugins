# CHANGELOG — USB Drive

本插件的项目级变更记录，最新在上。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.2.0]

composite 形态（daemon + dankbar-widget）的当前版本。

### Added

- udev 块设备事件监听，插入/拔出免轮询识别；`udevadm`/`lsblk` 缺失时降级为手动扫描。
- 设备清单与分区级用量：`lsblk`（含 `FSUSE%`）+ 一次批量 `df` 取字节级用量。
- 事件分类与 freedesktop 通知：插入 / 拔出 / 挂载 / 卸载，走 `dms notify` 统一通道。
- DankBar 小部件：已挂载分区角标、每设备一张卡片、分区级挂载开关与用量条、安全弹出。
- 安全弹出链：逐卷卸载，任一失败即停止，全部成功后才 `udisksctl power-off`。
- 打开动作：设置项命令前缀 → 默认文件管理器（校验 desktop entry 的 `Categories`）→ 默认终端。
- 设置项：设备筛选、扫描去抖、两类通知开关、插入时自动挂载、角标/设备数显示、文件管理器命令前缀。
- IPC：`status` / `list` / `rescan` / `mount` / `unmount` / `eject` / `open`。
- 中文翻译 `translations/zh_CN.json`。

### Security

- 所有外部命令以 argv 传递，不经过 shell；设备名先经 `[A-Za-z0-9._-]+` 白名单校验。

## [0.1.0] 及更早

来自原独立仓库 `dms-usb-manager`，本仓库未携带逐版本明细；
更早的变更历史保留在原仓库中。2026-10-13 两个插件仓库整合为本 monorepo。
