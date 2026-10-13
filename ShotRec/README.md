# Shot & Rec

GNOME Shell 风格的截图 / 录屏一体插件，为 DankMaterialShell 而生。

按一次热键：屏幕被冻结成静态画面，进入全屏选区界面，中央给出模式选择条（固定从"截图"开始），
方向键或鼠标点击切换模式、拖拽框选、`Enter` 确认、`Esc` 取消。录制中再按一次热键停止。

顶栏还有一枚状态图标（composite 插件的 `widget` 组件）：空闲时是 `screenshot_region`，
点击即触发 `toggle`；录制中变成红色呼吸圆点 + `stop_circle` + 已录时长 mm:ss（水平/垂直栏都显示）。
**右键点击图标**弹出快捷设置面板：与设置页共用同一个「截图 | 录屏」tab 标签组件
（`ShotRecConfigPanel.qml`），改动即时持久化（`PluginSettings` 机制）。

## 模式

| 模式 | 有选区时 | 无选区时 |
| --- | --- | --- |
| 截图 | 截取选区 | 截取全屏 |
| 窗口截图 | 截取焦点窗口（走 `dms screenshot window`）；**无窗口时自动退化为全屏截图**，通知会注明"当前没有窗口，已截取全屏" | 同左 |
| 录制 | 录制选区 | 录制全屏 |

## 设置（截图 | 录屏 两个 tab）

| tab | 项 | 说明 |
| --- | --- | --- |
| 截图 | 保存目录 | 默认 `~/Pictures/Screenshots`；**格式固定 PNG**（screencopy 采集即无损 PNG，全屏/窗口截图直接 mv 零转码，只有区域裁剪走一次 magick） |
| 截图 | 截图延时 / 复制到剪贴板 | 延时给"挪开遮挡物"用；剪贴板走 `wl-copy` |
| 录屏 | 保存目录 | 默认 `~/Videos` |
| 录屏 | 视频格式 | MP4 / WebM / MKV |
| 录屏 | 分辨率 | 原生 / 1080p / 720p（`wf-recorder -F scale`） |
| 录屏 | 质量 | 高 / 中 / 低 → CRF 三档（x264 系 18/23/28，VP9 28/34/40） |
| 录屏 | 帧率 | 自动 / 10 / 24 / 30 / 60（自动=省略 `-r`，只录画面变化） |
| 录屏 | 音频源 | 关闭 / 系统声音 / 麦克风 / 系统+麦克风（混音用旁路 ffmpeg amix 录 wav，停止时 `-c:v copy` 无损混流） |
| 录屏 | HEVC | 用 x265 替换 x264（仅 MP4/MKV；WebM 固定 VP9+Opus） |

参考设计稿里的"跟随鼠标 / 隐藏桌面图标 / 缩放"三项 wf-recorder 无对应能力，未实现。

## 快捷键接入

在 `~/.config/niri/config.kdl` 的 **extra binds** 段（`include "dms/binds.kdl"` 之后，
这样 `dms settings` 重新生成绑定时不会覆盖）里加入：

```kdl
binds {
    Print hotkey-overlay-title="截图/录屏: 选区" { spawn "dms" "ipc" "call" "shotrec" "toggle"; }
    Ctrl+Print hotkey-overlay-title="截图: 全屏" { spawn "dms" "ipc" "call" "shotrec" "setMode" "shot"; }
    Shift+Print hotkey-overlay-title="截图: 窗口" { spawn "dms" "ipc" "call" "shotrec" "setMode" "windowShot"; }
    Ctrl+Shift+Print hotkey-overlay-title="录屏: 整屏" { spawn "dms" "ipc" "call" "shotrec" "setMode" "record"; }
}
```

## IPC

```bash
dms ipc call shotrec toggle                     # 打开选区 / 停止录制
dms ipc call shotrec setMode shot               # 以指定模式打开选区（shot|windowShot|record）
dms ipc call shotrec setModeOnly record         # 只切换模式，不打开界面
dms ipc call shotrec stop                       # 停止录制
dms ipc call shotrec status                     # 查询状态
dms ipc call shotrec quickSettings              # 打开/关闭 bar 图标的快捷设置面板

# 不开选区，直接执行（适合脚本和额外快捷键）
dms ipc call shotrec shotNow ""                       # 立即全屏截图
dms ipc call shotrec shotNow "200,200 400x300"        # 立即截取区域（逻辑坐标）
dms ipc call shotrec recordNow ""                     # 立即开始整屏录制
dms ipc call shotrec recordNow "300,300 500x400"      # 立即开始区域录制

# 自动化/测试钩子（仅在选区界面打开时有效）
dms ipc call shotrec setSelection 200 200 500 300     # 直接设置选区（逻辑坐标）
dms ipc call shotrec confirm                          # 等价于按 Enter
```

`shotNow` / `recordNow` 的几何参数是**逻辑坐标** `"x,y WxH"`，再按一次 `recordNow` 停止。

## 外部依赖

| 工具 | 用途 |
| --- | --- |
| `dms screenshot` | 冻结画面 / 抓帧 / 窗口截图（niri 原生 screencopy，~0.08s） |
| `wf-recorder` | 录屏 |
| `ffmpeg` | 系统+麦克风混音（amix）与混流（mux） |
| `magick` | 从冻结帧裁剪截图（所见即所得） |
| `wl-copy` | 截图写入剪贴板 |
| `busctl` | 发送 freedesktop 通知（systemd 自带，无需安装） |

## 实现要点

- **秒开**：热键链路是 `niri bind → dms ipc (≈17ms) → 预映射透明遮罩窗口(live) → dms screenshot output (≈0.08s)`。
  窗口先以全透明、无键盘焦点的状态映射，抓帧与映射并行，帧就绪才置 `ready` 显示内容——
  按下到可见约 0.2s。曾用 `grim`，PNG 编码要 1.4s，是延迟主因。
- **live 阶段的防御**：键盘焦点、拖拽、按键都门控在 `phase === "selecting"`；
  抓帧回调里用 `grabSeq` 序号判断自己是否已过期，过期就删掉落盘文件，防止连按泄漏。
- **冻结优先**：先落盘再显示遮罩，所以画面里不会出现自己的遮罩；截图直接从冻结帧裁剪，和用户看到的像素完全一致。
- **选区"挖洞"是真像素**：遮罩下垫一层 `clip` 容器，内嵌一张与全屏同尺寸、按选区反向偏移的冻结帧 `Image`——
  直接对选区矩形拉伸整屏图会得到缩小版画面（曾经的 BUG）。
- **两套坐标，别搞混**（本机 niri scale 1.25 实测）：
  - `wf-recorder -g`、`setSelection`、IPC 几何参数收**逻辑坐标**。
  - 冻结帧 PNG 是**物理像素**，`magick -crop` 裁它必须用物理坐标。
  - 换算走 `CompositorService.getScreenScale()`，**不要**用 `screen.devicePixelRatio`（Qt 在 1.25 下会取整成 2）。
- **通知走统一通道**：保存成功的提示经 `org.freedesktop.Notifications.Notify`（busctl）发出——DMS 自己就是这台机器的通知守护进程，所以它和别的 App 通知一样进通知中心/弹窗体系，而不是顶部 island toast（`ToastService` 只留给错误兜底）。外部 `dms screenshot` 命令一律 `--no-notify --no-clipboard`，避免双份 toast。
  `Proc.runCommand` 按 id 去重且共享回调——并发抓帧必须用唯一 id（`shotrec.grab.${seq}`），同 id 会互相覆盖回调（曾经的漏通知 BUG）。
  局限：通知上的"打开文件夹"按钮做不了——action 回调要求发送方持有 well-known DBus 名，Quickshell 没有这个 API，路径放正文里自己复制。
- **录屏**：整屏 `wf-recorder -f`，区域 `wf-recorder -g "x,y WxH"`；停止走 `SIGINT`，等它自己收尾写文件。
- **录制状态只在 bar 图标上显示**，屏幕上不放 HUD——顶栏照录（同 GNOME），屏内浮层却会烙进录像。再点一次图标（或热键 `toggle`）即停止。
- **录屏时顶栏照录**，和 GNOME 默认行为一致。
- **自建 layer-shell 窗口**而不是用 `DankModal`：`DankModal.content` 要的是 `Component`，而且它挂在 DMS 的 modal 生命周期上，开别的弹窗会把选区界面顶掉。
- **bar widget**：`plugin.json` 声明 `"type": "composite"` + `components.widget`，组件用 `PluginComponent` 的
  `horizontalBarPill` / `verticalBarPill`，通过 `PluginService.pluginDaemonInstances[pluginId]` 直读 daemon 状态。
  激活方式：把 `{"id": "shotrec", "enabled": true}` 插进 `settings.json → barConfigs[].rightWidgets`。

## 踩过的坑

- **`plugins reload` 不重读 manifest**：daemon → composite 这种结构变化后，`widget status` 一直 `WIDGET_NOT_FOUND`。
  要先 `dms ipc call plugin-scan rescan shotrec` 再 reload。
- **QML 类型缓存**：reload 只对入口文件 cache-bust，被子组件按类型名引用的 QML 仍是旧的（改属性报
  `Cannot assign to non-existent property`）。解法：给文件改名（`CaptureOverlay.qml` → `ShotRecOverlay.qml`）强制 bust。
- **`triggerPopout()` 被 `pillClickAction` 短路**：只要设了 `pillClickAction`，`PluginComponent.triggerPopout()` 就永远走它、不碰 popout。右键要开自己的面板，得在 widget 内**自建 `PluginPopout` 实例**并复制基类的定位数学（`SettingsData.getPopupTriggerPosition` → `setTriggerPosition`）。
- **DMS 热重载有缓存**：插件加载失败时 `dms ipc call plugins reload` 会退回 `enablePlugin`，那条路径**不带 cache bust**，于是永远重读旧文件、报同一个早已修掉的错误。解法：手动把插件写进 `plugin_settings.json` 的 `enabled`，让它成功加载一次，之后 reload 才走带 `?t=` 的路径。
- **`PanelWindow` 的 `anchors` 没有 `margins`**：边距要写 `WlrLayershell.margins`。
- **数组形式传参不展开 `~`**：`["dms", "screenshot", ..., "-d", "~/x"]` 里的 `~` 是字面量，要先过 `Paths.expandTilde()`。
- **Enter 自动重复**：确认键按住会连发，`confirmSelection` 要先检查 `phase === "selecting"` 再置 idle，否则窗口截图弹两次 toast。
- **wf-recorder 的 `-a` 只认连接形式**：`-a <dev>` / `--audio <dev>`（空格分隔）会被当成没带设备、静默回落到默认 source（麦克风），必须写 `--audio=<dev>`。
- **WebM 装不下 AAC**：wf-recorder 音频 codec 默认 AAC，webm 容器直接 `Failed to write file header` 产出 0 字节文件——webm 且有音轨时要加 `-C libopus`。
- **改被引用的子组件 QML 后 reload 无效**：`plugin-scan reload` 只给入口文件 cache-bust，`ShotRecConfigPanel.qml` 这类兄弟组件仍是旧解析结果（报错行号停在旧版本）。可靠解法是 `systemctl --user restart dms.service`。
- **DMS 退出会把内存里的 pluginSettings 刷回磁盘**：测试改 `plugin_settings.json` 必须"停服务 → 改文件 → 起服务"，运行中改文件（含 mv 换 inode）不会被重读，重启前还会被旧内存覆盖。

## 开发

```bash
ln -sfn ~/coding/inx-dms-plugins/ShotRec ~/.config/DankMaterialShell/plugins/shotrec
dms ipc call plugins reload shotrec     # 热重载入口；改 manifest 需先 plugin-scan rescan
qmllint ~/coding/inx-dms-plugins/ShotRec/*.qml      # 语法检查
```
