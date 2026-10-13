# CHANGELOG — Shot & Rec

本插件的项目级变更记录，最新在上。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
条目保留了开发时的实测数据（耗时、体积、电平），以便后续回归对比。

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
