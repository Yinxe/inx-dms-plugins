# CHANGELOG — Shot & Rec

> 本插件（dms-shotrec）的项目级变更记录，最新在上。
> 家目录全局台账（`~/.agents/CHANGELOG.md`）只登记配置/工具链类变更，插件代码变更一律记在这里。
> v0.2.0 及更早的历史仍在全局台账 `[DMS/插件]` 条目中（2026-10-13 10:50 / 11:50 / 12:00 / 12:05 / 12:10 / 12:13 / 12:25）。

## 记录

- 2026-10-13 14:05 [v0.3.2] **取消 GIF 录制、截图固定 PNG**（原因：用户确认 GIF 事后转码不值得保留；截图格式既然只有全屏 PNG 免转码、JPG/WebP 必然要 magick 解码+重编码，索性 PNG 够用）。
  - **GIF 全链路移除**：`videoFormat` 只认 mp4/webm/mkv；`startRecording` 的 `recExt/needsPost` 只剩混音一种后处理；删除 `runGifEncode`，`postProcessRecording` 直接 mux→`finalizeRecording`（mux 失败仍回落到无声成品）；缓存清扫去 `gif-*.gif`；设置面板删 GIF 选项与说明；翻译删 2 个 GIF 键。
  - **截图去转码**：删 `shotFormat`/`shotQuality` 设置与 `imageQuality()`；`saveImageFrom` 重写——全屏/窗口（无裁剪）恒 `mv` 直存 PNG（连质量档位判断都没有了），区域裁剪 magick 固定 `png:compression-level=2`；剪贴板 mime 固定 `image/png`。设置面板截图页只剩 保存目录/延时/剪贴板 三项。
  - 版本 0.3.2。ffmpeg 依赖保留（系统+麦克风混音/混流仍需要）。
  - 验证：重启 DMS 后无 QML 报错，快捷设置弹出面板（含新面板结构）加载正常；shotNow 全屏产出 1920x1080 PNG（mv 零转码）、区域产出 500x375 PNG（逻辑 400x300×1.25 裁剪正确）。混音 mux 未实测（ffmpeg 命令与 v0.3.0 已验证的完全一致，仅控制流简化），请用户录一段"系统+麦克风"确认。

- 2026-10-13 13:48 [v0.3.1] **截图保存提速 + 设置页控件失联修复**（原因：用户观察到"截图文件慢慢写入 1~2 秒"、"改了图片格式截图还是 PNG"）。
  - **慢写入根因**：PNG 保存走 `magick freeze.png out.png` 全图解码+默认 zlib 重编码，1080p 实测 **2.19s**（抓帧本身仅 0.11s）。全屏 PNG 时冻结帧就是成品——改为直接 `mv` 进目标目录，shotNow→落盘实测 **144ms**；区域 PNG 裁剪保留 magick 但加 `-define png:compression-level=2`（2.4s→**256ms**，文件略大 ~27%）。
  - **设置不生效根因**：DMS `PluginSettings` 注入 `pluginService`（设置页由 PluginListItem Loader 事后赋值）与 `pluginDataChanged` 刷新**只遍历直接 content 子项**；我们把控件嵌在包装 Column + `ShotRecConfigPanel` 里 → 设置页上控件永远显示默认值、与存储失联。修复：`ShotRecSettings/ShotRecQuickSettings` 摊平为直接子项，`ShotRecConfigPanel` 实现 `loadValue()` 把刷新扇出到两个页面的全部控件。
  - 验证：jpg/medium 配置经 stop→edit→start 后 shotNow 产出 1920x1080 JPEG(118KB) ✓；全屏/区域 PNG 延迟 144ms/256ms ✓。
  - 备注：用户此前在设置页改的格式没落盘，部分还叠加了"多会话并发重启 DMS + 关机刷盘互相覆盖"（另一 agent 会话同期在改 plugin_settings.json）。

- 2026-10-13 13:25 [v0.3.0] **配置系统重构：截图/录屏双 tab 面板 + 全量视频参数**（原因：用户要求视频配置对齐参考截图项、截图可配格式与质量、设置 UI 紧凑化用 tab、去掉"记住上次模式"、模式支持鼠标点击）。
  - **daemon**（`ShotRecDaemon.qml`）：新增设置项 `shotFormat`(png/jpg/webp)、`shotQuality`(high/medium/low→magick -quality)、`videoFormat`(mp4/webm/mkv/gif)、`videoResolution`(native/1080p/720p→`-F scale`)、`videoQuality`(crf 三档，webm 与 x264 系分开)、`videoFps`(auto/10/24/30/60，auto=省略 -r 走损伤帧)、`videoAudio`(off/system/mic/mixed)；删除 `rememberMode`，选区固定停在截图模式。
    保存链路统一为 `saveImageFrom`（缓存 PNG → magick 裁剪+转格式+质量 → imageDir）；录制链路 `startRecording` 直写 videoDir，GIF/混音两格式走"缓存中间件 → 后处理 → mv 成品"：GIF 用 ffmpeg palettegen/paletteuse 转码，混音（系统+麦克风）用旁路 `ffmpeg -f pulse` amix 录 wav 再 `-c:v copy` 混流；缓存目录启动清扫 + 每次收尾 rm。
  - **wf-recorder 两个实测坑**：① `--audio=<dev>` 必须用等号连接形式，空格形式被忽略、静默回落到默认设备（麦克风）；② webm 容器下 wf-recorder 仍默认塞 AAC 音轨，muxer 直接拒绝（"Only VP8 or VP9…"）产出 0 字节文件——须 `-C libopus`。系统声音=`@DEFAULT_MONITOR@`、麦克风=`@DEFAULT_SOURCE@`（volumedetect 实测 -23dB vs -91dB 区分）。
  - **参考项取舍**：跟随鼠标 / 隐藏桌面图标 / 缩放三项 wf-recorder（0.7 系）无对应能力，未实现；HEVC 开关保留（仅 MP4/MKV 生效）。
  - **设置 UI**：新建共享组件 `ShotRecConfigPanel.qml`（截图|录屏 tab 标签页，pill 样式，StackLayout 高度随当前页动画），`ShotRecSettings.qml`（设置页）与 `ShotRecQuickSettings.qml`（状态栏右键弹出）都嵌它；为紧凑去掉了"打开目录"按钮与次要说明文字。
  - **overlay**（`ShotRecOverlay.qml`）：模式 chip 支持鼠标点击（`z: 2` 抬到拖拽层之上）。
  - **翻译**：`translations/zh_CN.json` 全量重写对齐新键。
  - **依赖**：plugin.json 加 `ffmpeg`（GIF 转码与混音），版本 0.3.0。
  - **验证**：webm/720p/10fps/系统声音、gif/混音、mkv/麦克风、默认 PNG 四批端到端全过（ffprobe 校验编码/分辨率/帧率/音轨电平，缓存目录无残留）；双 tab 弹出面板截图目检中文齐全、不再溢出屏幕。
  - **环境坑（非本仓库代码）**：Quickshell 对插件兄弟 QML 的解析结果按 URL 缓存，`plugin-scan reload` 只给入口文件 cache-bust，改 `ShotRecConfigPanel.qml` 这类被引用组件必须整会话重启 `systemctl --user restart dms.service` 才生效；DMS 退出时会把内存 pluginSettings 刷回 `plugin_settings.json`，测试改配置须"停服务→改文件→起服务"。
