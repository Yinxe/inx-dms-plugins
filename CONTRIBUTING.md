# 参与贡献

欢迎为 inx-dms-plugins 提 issue 和 PR。

## 环境

- [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) ≥ 1.6.0
- 各插件的外部依赖见其 README 的「外部依赖」表
- 建议装 `qmllint`（`qt6-declarative` 一类包）做 QML 语法检查

把插件目录软链进 DMS 的插件运行时目录，改完热重载即可：

```bash
mkdir -p ~/.config/DankMaterialShell/plugins
ln -sfn "$PWD/ShotRec"   ~/.config/DankMaterialShell/plugins/shotrec
ln -sfn "$PWD/UsbDrive"  ~/.config/DankMaterialShell/plugins/usbDrive
ln -sfn "$PWD/SshMan"    ~/.config/DankMaterialShell/plugins/sshMan

dms ipc call plugins reload shotrec    # 或 usbDrive / sshMan
qmllint ShotRec/*.qml UsbDrive/*.qml SshMan/*.qml
```

两个已知的重载陷阱（详见 [`ShotRec/README.md`](ShotRec/README.md) 的「踩过的坑」）：
改动 `plugin.json` 结构要先 `dms ipc call plugin-scan rescan <id>`；
改动被引用的子组件 QML 常常需要 `systemctl --user restart dms.service` 才生效。

## 提 issue

按 [`.github/ISSUE_TEMPLATE/bug-report.yml`](.github/ISSUE_TEMPLATE/bug-report.yml) 的字段填写，
请尽量带上：

- 插件与版本（`plugin.json` 的 `id` / `version`）
- DMS 与 compositor 版本（`dms --version`，niri / hyprland 等）
- 复现步骤，以及是必现还是偶发
- `journalctl --user -u dms.service -b | grep -E '\[(shotrec|usbDrive)\]'` 的输出
- Wayland 相关问题的话，附上显示器 scale（坐标换算类 bug 高度依赖它）

## 改代码的约定

- **保持单插件单目录**：插件之间不互相引用，不共享 QML 模块。共享逻辑宁可复制。
- **外部命令一律 argv 传递，不拼 shell**。涉及设备名、路径、卷标等外部可控字符串时，
  先做白名单校验（可参考 `UsbMonitorDaemon.qml` 的 `safeName()`）。
- **每个新增设置项都要三处齐全**：daemon 读取（默认值集中定义，不要内联 fallback）、
  设置页控件、`translations/zh_CN.json` 的键。
- **文案走 `I18n.trFor(<pluginId>, ...)`**，英文原文作 key。
- **数组属性用重新赋值代替就地修改**，否则小部件的绑定不会失效。
- 改动行为或修 bug，同步更新对应插件的 `CHANGELOG.md` 和 `README.md`；
  有破坏性变更时 bump `plugin.json` 的 `version`。

## PR

- 一个 PR 做一件事；纯文档修订可以直接说清楚，不需要复现步骤。
- 提交信息用现在时说明变更内容，仓库历史以中文为主，中英都可接受。
- PR 里请写明你实际验证过的路径（命令 + 观察到的结果）；没验证的部分明确说没验证。

## 想要一个新插件

在仓库根新建 `<PluginName>/`，至少包含 `plugin.json`、组件 QML、`translations/zh_CN.json`、
`README.md`、`CHANGELOG.md`，并在根 `README.md` 的插件列表表格里加一行。
清单字段与组件架构见 [`docs/plugin-development.md`](docs/plugin-development.md)。
