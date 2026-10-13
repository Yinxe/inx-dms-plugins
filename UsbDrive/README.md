# USB Drive

USB 存储设备的监听与管理插件，为 DankMaterialShell 而生。

后台服务订阅 udev 块设备事件，插入/拔出无需轮询即可识别；设备清单来自 `lsblk`，
已挂载分区的字节级用量来自 `df`。插拔与挂载/卸载事件走 freedesktop 通知通道
（即 DMS 自己的通知中心），DankBar 上的小部件则给出每个设备的卡片、分区级挂载开关、
用量条和「安全弹出」。版本变更见 [CHANGELOG.md](CHANGELOG.md)。

## 行为

- **识别**：`tran=usb` 或内核可移除标记（可配置为只认其中之一）。Super-floppy
  （整盘文件系统、无分区表）会作为第一个卷列出。
- **事件分类**：对比上一次扫描结果，区分插入 / 拔出 / 挂载 / 卸载；拔出时带挂载点的卷
  会同时算作一次卸载。首次扫描只建立基线，不弹通知。
- **安全弹出**：`udisksctl power-off` 不会替你卸载，所以这是一条链——逐个卸载该设备的
  挂载卷，任一失败即停止（卷被占用意味着还有数据在写，此时绝不能断电），全部卸载成功后才断电。
- **自动挂载**（默认关闭）：插入后延迟读一次 `lsblk`（usb_storage 的 SCSI 扫描需要 1s 左右，
  此时分区表往往还没出现），挂载其中带可用文件系统的最大分区——即同时带 EFI / 恢复小分区的
  U 盘上的数据分区。
- **打开**：优先用设置里指定的文件管理器命令前缀；留空则解析 `inode/directory` 的默认关联，
  并读取其 desktop entry 的 `Categories` 确认它真是文件管理器（磁盘分析器也可能认领这个 MIME），
  再退化为 DMS 配置的默认终端。对未挂载的卷点「打开」会先挂载，等扫描到挂载点后再打开。

## 小部件

胶囊上是 `usb` / `usb_off` 图标 + 已挂载分区数角标（可选再显示设备数量）。
弹出面板每个设备一张卡片：设备副标题（厂商 · 容量 · 序列号 · 可移除/固定盘）、
设备级用量条、每个分区一行（标签/挂载点、用量文案、打开按钮、挂载开关）。
头部有刷新按钮，并显示 udev 监听是否可用（不可用时提示手动刷新）。

用量条按占用比例变色：>75% 警告色、>90% 错误色。未挂载的卷没有用量数据，
此时不画空条——空条会被读成"已格式化且为空"。

## 设置

| 分组 | 项 | 默认 | 说明 |
| --- | --- | --- | --- |
| 识别 | 设备筛选 | USB 或可移除 | 仅 USB 传输 / 仅内核可移除标记 / 两者都认 |
| 识别 | 扫描去抖 | 800ms | 插入事件后等多久再读 `lsblk`，让分区稳定 |
| 通知 | 插入与拔出 | 开 | 设备出现或被拔出时提示 |
| 通知 | 挂载与卸载 | 关 | 提示分区挂载点（udisks 通常在插入后一秒左右挂载）；卡片已直接显示该状态，故默认关 |
| 挂载 | 插入时自动挂载 | 关 | 为新插入的设备挂载最大的可用分区 |
| 状态栏组件 | 已挂载分区角标 | 开 | 胶囊上显示已挂载分区数 |
| 状态栏组件 | 显示设备数量 | 关 | 图标下方再显示检测到的设备数 |
| 状态栏组件 | 文件管理器 | 空 | 「打开」的命令前缀，可带参数，不经过 shell 传递 |

## IPC

```bash
dms ipc call usbDrive status            # 设备数 / 监听状态 / 上次扫描 / 进行中任务
dms ipc call usbDrive list              # 设备清单（含挂载状态）
dms ipc call usbDrive rescan            # 立即重新扫描

dms ipc call usbDrive mount sdb1        # 挂载分区
dms ipc call usbDrive unmount sdb1      # 卸载分区
dms ipc call usbDrive eject sdb         # 安全弹出整台设备（先卸载全部卷再断电）
dms ipc call usbDrive open sdb1         # 打开（未挂载则先挂载再打开）；参数也可传设备名
```

设备名/分区名都不做拼接执行：只接受 `[A-Za-z0-9._-]+`，`udisksctl` 一律以 argv 调用，
不经过 shell，因此卷标里的引号或空格无法注入命令。

## 外部依赖

| 工具 | 用途 |
| --- | --- |
| `udevadm` | 订阅块设备事件（缺失时降级为手动扫描） |
| `lsblk` | 设备/分区清单与文件系统占用率 |
| `df` | 已挂载卷的字节级用量（一次批量调用取全部卷） |
| `udisksctl` | 挂载、卸载、断电 |
| `xdg-mime` + desktop entry | 解析默认文件管理器 |
| `dms` | `dms notify` 走统一通知通道 |

## 实现要点

- **UI 路径不打 IPC**：小部件通过 `PluginService.pluginDaemonInstances["usbDrive"]`
  直读 daemon 状态，和 ShotRec 的 bar 图标同一套 composite 模式。
- **数组属性要重新赋值**：`activeJobs` / `drives` 每次变更都换新数组，就地改动会让
  小部件的委托绑定收不到失效通知。
- **通知走 `dms notify` CLI**：卷标是用户可控文本，手写 `a{sv}` GVariant 字典时
  一个引号就能砸穿；argv 传递既安全又直接落进通知中心。失败原因则用 `ToastService`
  做即时反馈（`udisksctl` 把 "Device is busy" 之类原因写在 stderr，原样转述比猜可靠）。
- **每个动作一个一次性 `Process`**：`Proc.runCommand` 会吞掉 stderr，且同 id 的第二次调用
  会覆盖前一次的回调——一次慢卸载可能把结果交给不相关的挂载请求。
- **单设备单任务**：同一 `kind:device` 只允许一个任务在飞，双击不会排队两次断电。
- **开关由 lsblk 驱动，不由点击驱动**：`DankToggle` 只在 udisks 真的挂载成功后才移动，
  所以界面不会显示一个没发生的状态。

## 踩过的坑

- **`property var onTap` + `{ ... }` 赋值**：QML 会把它当成对象创建时求值的绑定，
  于是每个委托在面板打开的瞬间就各自执行了一次动作——曾经表现为弹出面板一出现，
  所有设备都收到了 `udisksctl power-off`。正确写法是 `signal tap` + `onTap:` 处理器。
- **`lsblk` 不能加 `-d`**：`-d` 会抑制子设备，分区就再也不出现在输出里。
  也不加 `-p`：`NAME` 需要保持裸设备名，动作辅助函数和 `safeName()` 都按这个假设写。
- **`running` 属性别既绑定又命令式写**：`running: <binding>` 加上定时器里的
  `running = true` 会互相打架，第一次写入静默杀掉绑定。监听器的生命周期全部改成显式写入。
- **设置默认值要在一个地方定义**：daemon 和小部件各自内联 fallback，
  会让 `notifyMountEvents` 变成"代码里 true、设置页上 false"。
- **`df` 的输出解析**：不加挂载点列，每个设备一列，卷标里的空白就不会挪动要解析的字段；
  首行表头随 locale 变化，所以只能按行 `slice(1)` 跳过，不能按表头文字匹配。

## 开发

```bash
ln -sfn "$PWD" ~/.config/DankMaterialShell/plugins/usbDrive   # 在本插件目录内执行
dms ipc call plugins reload usbDrive      # 热重载入口；改 manifest 需先 plugin-scan rescan
qmllint *.qml
```

## 国际化

组件文案通过 `I18n.trFor("usbDrive", ...)` 取译，中文译文在
[`translations/zh_CN.json`](translations/zh_CN.json)。新增文案请同时补键，
缺键时界面会退回英文原文。
