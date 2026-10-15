# CHANGELOG — Shot & Rec

本插件的项目级变更记录，最新在上。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
条目保留了开发时的实测数据（耗时、体积、电平），以便后续回归对比。

## [0.4.2] — 2026-10-15

**编辑窗口第二轮迭代：选区底子、矩形马赛克、工具栏融合、撤销修复**。

- **选区底子**：区域截图进编辑器时，daemon 先用一条 `ffmpeg crop` 把冻结帧裁成选区图（`edit-base-*.png`）再打开——编辑框底子是**选区本身**而非全屏原图。重新裁剪改为「视图」模型：`crop` 为全图归一化的视口矩形，`shot` 图永不自身裁剪（马赛克 `drawImage` 仍采全图真实像素），外层裁剪容器只显示视口，因此**重新裁剪后底子图即时变化**，且已有标注按视口重映射（`applyCrop`）不位移。
- **矩形马赛克**：由画笔式涂抹改为**拖拽矩形区域**，逐格采一个全图像素邻近放大铺满→真马赛克；区域带白色描边；强度加大（块尺寸 0.03/0.05/0.08 图宽）。裁剪工具拖拽时视口内显示虚线选择框。
- **工具栏融合**：第二行去掉重复的居中快捷键提示，把 `Ctrl+Z / Esc / Enter` 直接并入「撤销/清空/取消/保存」按钮文字，不再重复出现。
- **撤销修复**：`onVisibleChanged` 用 `Qt.callLater` 抢焦点（`DankFloatingWindow` 无 `active` 属性，误用 `onActiveChanged` 会导致整个插件加载失败）；`Ctrl/Cmd+Z` 判定放宽。
- 验证：区域 200,200 500x300（scale 1.25）→ 编辑器底子为 625x375 选区图；矩形马赛克 + 保存 → 产物 625x375、左上马赛克区块与白框对齐；双行工具栏第二行按钮含内联快捷键、无重叠。

## [0.4.1] — 2026-10-15

**编辑窗口迭代：双行工具栏、马赛克涂抹、文字输入修复、粗细选择器重做**。

- **工具栏双行**：第一行=工具组（画笔/矩形/箭头/文字/马赛克/裁剪，图标+文字胶囊）| 颜色 7 颗（选中内点+描边）| 粗细 3 档；第二行=撤销/清空（左）、快捷键提示（中）、取消/保存（右）。窗口宽度取「图片/两行工具栏」最大值，提示不再被裁。
- **马赛克**：画笔式涂抹，`drawImage(shot, …)` 邻近缩放把原图像素按方块贴回标注层——预览即成品，保存链路零新增处理；粒度跟随粗细档位（0.02/0.03/0.045 图宽）。工具键扩到 `1`–`6`。
- **文字输入修复**：旧实现点击后 `forceActiveFocus()` 与 `visible=true` 同帧执行拿不到焦点。改为 `textEditing` 状态 + 输入卡片（深色描边气泡），`Qt.callLater` 拿焦点，`Enter`/失焦提交、`Esc` 只收卡片；`saveEdit` 前先提交未落定的文字。
- **粗细选择器**：由圆点改为按真实线宽绘制的横线按钮（选中主色+底色胶囊），语义一目了然。
- IPC 新增 `editorTestMosaic` 钩子（与 `editorTestArrow` 同用途）。
- 验证：（待补实测数据）

## [0.4.0] — 2026-10-15

**截图后编辑**（截图确认不再直接落盘，先弹独立编辑窗口；同时全插件去 ImageMagick，图像管线统一为 ffmpeg）。

- **新增 `ShotRecEditor.qml`**：DankFloatingWindow 独立窗口（SshMan 同款先例），画笔/矩形/箭头/文字标注 + 二次裁剪（初始裁剪=选区），7 色 3 档粗细，撤销/清空。`Enter` 保存、`Esc` 放弃（不落盘）、`1`–`5` 切工具、`Ctrl+Z` 撤销。标注坐标按图片归一化存 `Canvas`，抗窗口缩放。
- **保存链路**：无标注且未改裁剪 → 原 mv/单条 crop 路径，零合成；有标注 → 只 grab 透明标注层（`grabToImage`），一条 ffmpeg `crop+scale+overlay` 合成出**物理像素** PNG。尺寸读 `Image.sourceSize`，不靠外部 identify。编辑过程本身零外部进程。
- **去 magick**：`saveImageFrom` 区域裁剪改 `ffmpeg -vf crop`；`plugin.json` 依赖移除 `magick`（wf-recorder/ffmpeg/wl-copy 保留）。
- 设置页/快捷面板新增「截图后打开编辑器」开关（默认开，关=恢复 0.3.x 直接保存行为）；`shotNow`/`recordNow` 脚本路径不经编辑器，行为不变。
- IPC：`status` 编辑器打开时返回 `editing`；新增测试钩子 `editorConfirm` / `editorCancel`；缓存清扫补 `edit-*.png`；编辑器打开时 `toggle` 不重开选区。
- 验证：全屏未改动 → 编辑器 Enter 直存 1920x1080（纯 mv 零 ffmpeg）；区域 400x300（scale 1.25）→ 存 500x375（单条 ffmpeg crop）；区域+测试箭头 → 500x375 且产物含 798 个红像素（crop+scale+overlay 一条命令合成）；`editorCancel` 不落盘、缓存无残留；关「截图后打开编辑器」→ 恢复直接保存（300x200 → 375x250）。踩坑：多输入合成的 PNG 输出必须 `-frames:v 1 -update 1`（否则 image2 muxer 报 "Cannot write more than one file"）；`plugins reload` 不刷新被引用的子组件（改 `ShotRecEditor.qml` 后需 `systemctl --user restart dms.service`，README 早有记载）。

## [0.3.2] — 2026-10-13

**取消 GIF 录制、截图固定 PNG**（GIF 事后转码不值得保留；截图格式里只有全屏 PNG 免转码，JPG/WebP 必然要 magick 解码+重编码，索性 PNG 够用）。

- **GIF 全链路移除**：`videoFormat` 只认 mp4/webm/mkv；`startRecording` 的 `recExt/needsPost` 只剩混音一种后处理；删除 `runGifEncode`，`postProcessRecording` 直接 mux→`finalizeRecording`（mux 失败仍回落到无声成品）；缓存清扫去 `gif-*.gif`；设置面板删 GIF 选项与说明；翻译删 2 个 GIF 键。
- **截图去转码**：删 `shotFormat`/`shotQuality` 设置与 `imageQuality()`；`saveImageFrom` 重写——全屏/窗口（无裁剪）恒 `mv` 直存 PNG（连质量档位判断都没有了），区域裁剪 magick 固定 `png:compression-level=2`；剪贴板 mime 固定 `image/png`。设置面板截图页只剩 保存目录/延时/剪贴板 三项。
- 版本 0.3.2。ffmpeg 依赖保留（系统+麦克风混音/混流仍需要）。
- 验证：重启 DMS 后无 QML 报错，快捷设置弹出面板（含新面板结构）加载正常；shotNow 全屏产出 1920x1080 PNG（mv 零转码）、区域产出 500x375 PNG（逻辑 400x300×1.25 裁剪正确）。
- 未验证：混音 mux 未实测（ffmpeg 命令与 v0.3.0 已验证的完全一致，仅控制流简化），欢迎录一段「系统+麦克风」后反馈。

## [0.3.1] — 2026-10-13

**截图保存提速 + 设置页控件失联修复**（现象：截图文件慢慢写入 1~2 秒；改了图片格式截图还是 PNG）。

- **慢写入根因**：PNG 保存走 `magick freeze.png out.png` 全图解码+默认 zlib 重编码，1080p 实测 **2.19s**（抓帧本身仅 0.11s）。全屏 PNG 时冻结帧就是成品——改为直接 `mv` 进目标目录，shotNow→落盘实测 **144ms**；区域 PNG 裁剪保留 magick 但加 `-define png:compression-level=2`（2.4s→**256ms**，文件略大 ~27%）。
- **设置不生效根因**：DMS `PluginSettings` 注入 `pluginService`（设置页由 PluginListItem Loader 事后赋值）与 `pluginDataChanged` 刷新**只遍历直接 content 子项**；控件嵌在包装 Column + `ShotRecConfigPanel` 里 → 设置页上控件永远显示默认值、与存储失联。修复：`ShotRecSettings/ShotRecQuickSettings` 摊平为直接子项，`ShotRecConfigPanel` 实现 `loadValue()` 把刷新扇出到两个页面的全部控件。
- 验证：jpg/medium 配置经 stop→edit→start 后 shotNow 产出 1920x1080 JPEG(118KB) ✓；全屏/区域 PNG 延迟 144ms/256ms ✓。
- 附带发现：DMS 退出会把内存中的 pluginSettings 刷回磁盘，多个进程并发重启 DMS 时配置会互相覆盖——这也是此前设置"改了没落盘"的部分原因。

## [0.3.0] — 2026-10-13

**配置系统重构：截图/录屏双 tab 面板 + 全量视频参数**（视频配置对齐常见录屏参数项、截图可配格式与质量、设置 UI 用 tab 紧凑化、去掉"记住上次模式"、模式支持鼠标点击）。

- **daemon**（`ShotRecDaemon.qml`）：新增设置项 `shotFormat`(png/jpg/webp)、`shotQuality`(high/medium/low→magick -quality)、`videoFormat`(mp4/webm/mkv/gif)、`videoResolution`(native/1080p/720p→`-F scale`)、`videoQuality`(crf 三档，webm 与 x264 系分开)、`videoFps`(auto/10/24/30/60，auto=省略 -r 走损伤帧)、`videoAudio`(off/system/mic/mixed)；删除 `rememberMode`，选区固定停在截图模式。
  保存链路统一为 `saveImageFrom`（缓存 PNG → magick 裁剪+转格式+质量 → imageDir）；录制链路 `startRecording` 直写 videoDir，GIF/混音两格式走"缓存中间件 → 后处理 → mv 成品"：GIF 用 ffmpeg palettegen/paletteuse 转码，混音（系统+麦克风）用旁路 `ffmpeg -f pulse` amix 录 wav 再 `-c:v copy` 混流；缓存目录启动清扫 + 每次收尾 rm。
- **wf-recorder 两个实测坑**：① `--audio=<dev>` 必须用等号连接形式，空格形式被忽略、静默回落到默认设备（麦克风）；② webm 容器下 wf-recorder 仍默认塞 AAC 音轨，muxer 直接拒绝（"Only VP8 or VP9…"）产出 0 字节文件——须 `-C libopus`。系统声音=`@DEFAULT_MONITOR@`、麦克风=`@DEFAULT_SOURCE@`（volumedetect 实测 -23dB vs -91dB 区分）。
- **能力取舍**：跟随鼠标 / 隐藏桌面图标 / 缩放三项 wf-recorder（0.7 系）无对应能力，未实现；HEVC 开关保留（仅 MP4/MKV 生效）。
- **设置 UI**：新建共享组件 `ShotRecConfigPanel.qml`（截图|录屏 tab 标签页，pill 样式，StackLayout 高度随当前页动画），`ShotRecSettings.qml`（设置页）与 `ShotRecQuickSettings.qml`（状态栏右键弹出）都嵌它；为紧凑去掉了"打开目录"按钮与次要说明文字。
- **overlay**（`ShotRecOverlay.qml`）：模式 chip 支持鼠标点击（`z: 2` 抬到拖拽层之上）。
- **翻译**：`translations/zh_CN.json` 全量重写对齐新键。
- **依赖**：`plugin.json` 加 `ffmpeg`（GIF 转码与混音），版本 0.3.0。
- **验证**：webm/720p/10fps/系统声音、gif/混音、mkv/麦克风、默认 PNG 四批端到端全过（ffprobe 校验编码/分辨率/帧率/音轨电平，缓存目录无残留）；双 tab 弹出面板中文齐全、不再溢出屏幕。
- **环境坑（非本插件代码）**：Quickshell 对插件兄弟 QML 的解析结果按 URL 缓存，`plugin-scan reload` 只给入口文件 cache-bust，改 `ShotRecConfigPanel.qml` 这类被引用组件必须整会话重启 `systemctl --user restart dms.service` 才生效；DMS 退出时会把内存 pluginSettings 刷回 `plugin_settings.json`，测试改配置须"停服务→改文件→起服务"。

## 0.2.0 及更早

来自原独立仓库 `dms-shotrec`，本仓库未携带逐版本明细；更完整的开发记录保留在原仓库历史中。
2026-10-13 两个插件仓库整合为本 monorepo。
