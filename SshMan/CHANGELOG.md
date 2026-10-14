# CHANGELOG — SSH Manager

本插件的项目级变更记录，最新在上。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.2.0]

### Added

- 双栏文件管理器窗口（`SshFileManager`，daemon 自持的 `DankFloatingWindow`）：左本地
  （`FolderListModel`）右远端，目录导航、路径直达、Ctrl 多选，上传/下载分别走
  `rsync -a --info=progress2`（远端缺 rsync 时自动回退 `scp -r`，本会话不再优先 rsync）。
- 远端浏览：`ssh <alias> find -maxdepth 1 -printf` 制表符记录，空格名称安全；
  符号链接跟随目标类型。全部 BatchMode——浏览/传输要求密钥认证，密码主机落
  明确错误态（auth/hostkey/network/remote-tools 分类，文案指向 `ssh-copy-id`）。
- 传输进度：`\r` 刷新行解析（rsync/scp 两种计量格式，stdout/stderr 双路挂同一解析器），
  每行进度条 + 速率 + 百分比；取消发 `SIGTERM`；并发上限 4（防 sshd MaxStartups）；
  整批结束一条 `dms notify` 汇总（设置项 `notifyOnTransferComplete`，默认开）。
- 关窗仅隐藏，在飞传输继续；上传完成后远端列表自动刷新。
- IPC `files <alias>`；主机卡片新增 `folder` 动作按钮。
- 外部依赖：`rsync` / `scp` / `find`。

### Fixed

- 翻译文件补齐 0.1.0 遗漏的三个设置项标签键，修正拼错的
  `Match block not evaluated statically: %1` 键。

## [0.1.0]

初始版本，composite 形态（daemon + dankbar-widget + launcher），要求 DMS ≥ 1.6.0。

### Added

- `~/.ssh/config` 解析（含 Include 展开、`~`、目录形态与仅末段 glob）；OpenSSH
  first-wins 语义，`Host` 多 pattern 分块，`Match` 块跳过并记 warning。
- 文件末尾托管区块（`# >>> sshMan managed hosts >>>` 标记），UI/IPC 可添加、编辑、删除托管主机；
  区块外文本逐字节保留。重名主机拒绝添加/改名（first-wins 下用户同名块必然生效）。
  增删改都先做一次全新解析再动文字，外部编辑不会被上次缓存吞掉。
- 写链：全新解析 → `mkdir -p` → `realpath -m` → `cp -p` 备份 `.sshman.bak` →
  FileView 原子写 → `chmod 600`。软链配置写向目标、链本身保留。
- 连接：DMS 默认终端执行 `ssh <alias>`，终端解析链与 DMS 核心一致（`terminalCommand`
  设置 → SessionData 覆盖/$TERMINAL → 已装终端探测 → `xterm` 兜底）。交互认证
  （密码/2FA）在弹出的终端里照常完成，插件不接触密码。
- 探活：`ssh -o BatchMode=yes -o ConnectTimeout=N` 一次性任务，stderr 失败原因记入主机并在卡片显示。
- 活跃会话轮询：`ps -o pid=,etimes=,args= -C ssh`，短选项解析取目标反查主机清单，
  ControlPersist 主连接标成 master；`showUnresolved` 决定是否列出未解析进程；
  `kill <pid>` 终止。新会话/会话消失可配置通知（`dms notify` 统一通道）。
- DankBar 小部件：terminal 图标 + 会话数角标；popout 主机卡片（连接/探活/复制/编辑/删除）、
  折叠式添加/编辑表单（默认收起为“添加主机”按钮，落盘或取消后自动收起）、
  活跃会话列表。同主机操作在飞时按钮禁用。
- DankLauncher 集成：触发词 `!ssh`，模糊过滤主机，回车连接，右键菜单复制/探活/删除。
- 设置项：trigger / terminalCommand / testTimeoutSeconds / pollIntervalSeconds /
  notifyOnNewSession / notifyOnSessionEnd / showUnresolved。
- IPC：`status` / `list` / `live` / `refresh` / `connect` / `test` / `add` / `update` / `remove` / `kill`。
- 中文翻译 `translations/zh_CN.json`。
