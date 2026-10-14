# SSH Manager

SSH 连接管理插件，为 DankMaterialShell 而生。composite 形态（daemon + dankbar-widget + launcher）：
主机清单解析自 `~/.ssh/config`（含 `Include`），插件在同一文件末尾维护一个托管区块，
可在界面上添加/编辑/删除托管主机；「连接」在 DMS 默认终端里执行 `ssh <alias>`，交互式认证不受影响；
还提供独立的双栏文件管理器窗口，本地与远端文件系统对拷、带传输进度。
版本变更见 [CHANGELOG.md](CHANGELOG.md)。

## 行为

- **解析**：按 OpenSSH 语义处理 `Host` 多 pattern、选项 first-wins（同名选项取第一个匹配块的值）、
  `~` 展开、Include 相对路径与仅末段 glob（目录形态补 `/*`，跳过点开头与 `~` 结尾的文件名）。
  `Match` 块无法静态求值，整块跳过并记入 warning。配置文件不存在时清单为空，不算错误。
- **托管区块**：文件末尾的
  `# >>> sshMan managed hosts >>>` / `# <<< sshMan managed hosts <<<` 之间。
  新区块排在最后正是 first-wins 的考虑——托管条目永远不压过用户手写的配置；
  因此与已解析主机重名的添加会被**拒绝**，而不是写进去静默失效。
- **写文件**：每次增删先重新读一遍配置再动文字（外部编辑不会被上一次的缓存吞掉），
  写前 `cp -p` 备份为 `config.sshman.bak`（仅当原文件存在且有内容），
  FileView 原子写（rename-over）——原子写会把软链替换成普通文件，所以写目标先经
  `realpath -m` 解析；随后 `chmod 600`，ssh 拒绝过宽的权限。区块外文本逐字节保留。
- **连接**：`[终端, "-e", "sh", "-c", "ssh '<alias>'"]`，与 DMS 核心拉起终端的约定一致。
  终端依次取：设置项 `terminalCommand`（可带参数，argv 切分）→ DMS
  `SessionData.resolveTerminal()`（terminalOverride、`$TERMINAL`）→ DMS 探测到的已装
  终端（ghostty/kitty/foot/…）→ `xterm`。密码/2FA 这类交互认证在弹出的终端里照常完成，
  插件不接触也不存储密码；想免密就配置密钥认证（例如 `ssh-copy-id <alias>`）。
- **探活**：`ssh -o BatchMode=yes -o ConnectTimeout=N <alias> true` 一次性任务，
  失败原因（stderr 原文）记在该主机上，界面上直接看。仅密钥认证适用——
  密码/2FA 无法在后台应答，这类主机请直接走「连接」。
- **活跃会话**：按轮询间隔跑 `ps -o pid=,etimes=,args= -C ssh`，解析 argv 的短选项
  （带参短选项吞掉下一个 token；`-p2222` 这类内联值不吞）取第一个非选项 token 为目标，
  反查主机清单（alias / `user@host` / hostname）。查不到的裸 `ssh` 进程按设置项
  `showUnresolved` 决定显示与否。argv 含 `sleep N` 的是 ControlPersist 主连接，标成 master。
  `-C ssh` 无匹配时 `ps` 退出码为 1 且无输出——这是"没有会话"，不当错误处理。
- **通知**：检测到新会话/会话消失时走 `dms notify` 统一通道（默认前者开、后者关）。
- **文件互传**：主机卡片（非通配模板）的 `folder` 按钮或 `dms ipc call sshMan files <alias>`
  打开独立的双栏文件管理器窗口（本地 ↔ 远端）。所有远端操作都带 `-o BatchMode=yes`：
  **浏览与传输要求密钥认证**，密码主机落回明确的错误态并提示先 `ssh-copy-id`；
  连接动作不受影响（交互认证照常走终端）。远端列表用
  `ssh <alias> find <path> -maxdepth 1 -printf …`（要求远端为 GNU find），
  名称含空格的条目安全。传输优先 `rsync -a --info=progress2`，远端没有 rsync 时
  自动回退 `scp -r`（本会话内不再优先 rsync）；进度从 `\r` 刷新的计量行解析，
  stdout/stderr 两路都挂解析器（rsync 不同版本换过输出流）。取消发 `SIGTERM`。
  目标名冲突沿用 rsync 覆盖/合并语义，v1 不做覆盖确认。关窗只是隐藏，在飞传输继续。

## 小部件

胶囊上是 `terminal` 图标 + 活跃会话数角标。弹出面板三块：

- **主机卡片**：alias、`user@host:port`、来源文件与托管标记、最近一次探活结果；
  动作有连接 / 探活 / 复制 `ssh <alias>` / 文件 / 编辑 / 删除（编辑与删除仅托管主机；
  编辑会预填表单，可改名，改名同样拒绝与现有主机重复）。同一主机操作在飞时按钮禁用。
- **添加表单**：默认收起为一个「添加主机」按钮，点开才展开 alias / host / user / port
  四个输入（user、port 可留空）；落盘成功后自动收起并出现在列表，编辑同样展开此表单。
- **活跃会话**：pid、目标（或解析到的 alias）、运行时长，master 标记，终止按钮（`kill <pid>`）。

## DankLauncher

默认触发词 `!ssh`（设置可改，manifest 同步声明）。按 alias / hostname / user / port 模糊过滤，
回车即在终端连接；右键菜单可复制命令、探活、删除托管主机。

## 设置

| 分组 | 项 | 默认 | 说明 |
| --- | --- | --- | --- |
| 常规 | 触发词 | `!ssh` | DankLauncher 前缀 |
| 常规 | 终端命令 | 空 | 覆盖连接用终端，可带参数；留空走 DMS 默认终端 → $TERMINAL → 已安装终端 |
| 探活 | 探活超时 | 5s | BatchMode 探测的 `ConnectTimeout` |
| 会话 | 轮询间隔 | 5s | 活跃会话轮询周期 |
| 通知 | 新会话 | 开 | 检测到新活跃会话时通知 |
| 通知 | 会话结束 | 关 | 会话消失时通知 |
| 通知 | 传输完成 | 开 | 一批文件传输全部结束时通知 |
| 小部件 | 显示未解析进程 | 开 | 无法映射到清单的裸 `ssh` 进程也列出 |

## IPC

```bash
dms ipc call sshMan status              # 主机数 / 会话数 / 配置路径与存在性 / 进行中操作 / 探活结果
dms ipc call sshMan refresh             # 重新解析配置
dms ipc call sshMan list                # 主机清单（含托管标记）
dms ipc call sshMan live                # 活跃会话

dms ipc call sshMan connect lab         # 在默认终端打开 ssh lab
dms ipc call sshMan files lab           # 打开 lab 的双栏文件管理器窗口（需密钥认证）
dms ipc call sshMan test lab            # BatchMode 探活，结果进 status 与卡片
dms ipc call sshMan add lab 127.0.0.1 yinxin 22   # 添加托管主机（user/port 可留空 ""）
dms ipc call sshMan update lab web 10.0.0.2 "" ""  # 编辑：旧名、新名（可同名）、host、user、port
dms ipc call sshMan remove lab          # 删除托管主机（仅托管区块内的可删）
dms ipc call sshMan kill 12345          # 终止一个会话进程
```

所有外部可控串（alias / hostname / user / port / pid）先过白名单或整型校验，
命令一律 argv 传递、不拼 shell；唯一进入 `sh -c` 的是 `ssh '<alias>'`，
alias 已过白名单且单引号转义。

## 外部依赖

| 工具 | 用途 |
| --- | --- |
| `ssh` | 连接与 BatchMode 探活、远端目录列表 |
| `rsync` / `scp` | 文件上传/下载（rsync 优先，缺 rsync 的远端自动回退 scp） |
| `find` | 远端目录列表（要求远端为 GNU find） |
| `ps` | 活跃会话轮询 |
| `ls` / `cp` / `mkdir` / `realpath` / `chmod` | Include 展开与托管区块写回 |
| `dms` | `dms notify` 统一通知通道 |

## 实现要点

- **UI 路径不打 IPC**：小部件与 launcher 通过
  `PluginService.pluginDaemonInstances["sshMan"]` 直读 daemon，同 usbDrive/shotrec 模式。
- **数组/对象属性整体重赋值**（`hosts` / `sessions` / `testResults`），就地改动不会让
  小部件绑定失效。
- **需要 stderr 的地方用一次性 `Process`**：`Proc.runCommand` 吞 stderr 且同 id 后发覆盖前发回调；
  探活与写链各自建一个一次性 Component（stdout/stderr 用 SplitParser 汇聚，
  退出码从 `onExited` 拿——`StdioCollector.onStreamFinished` 作用域里没有 `exitCode`）。
- **超时靠 `Process.signal("SIGTERM")`**：Quickshell 0.3 的 Process 没有 terminate 方法。
- **launcher 根对象是 `Item`**：官方文档示例写的 `QtObject` 与实际 DMS 1.6 注入
  `pluginService` 的方式不符，参考 QuickNotes 用 Item。
- **先读后写**：增删都以一次全新的解析为起点。曾经的事故：外部改完文件直接走托管删除，
  操作基于上一次解析缓存的文本，把区块外的用户内容整段丢了（备份文件救回）。
- **插件自持窗口**：文件管理器是 daemon 声明的 `DankFloatingWindow`（`qs.Widgets`），
  与 ShotRec 在 daemon 里声明 `PanelWindow` 同理；常驻隐藏而非销毁，传输因此跨窗口开关存活。
- **进度解析不赌输出流**：rsync 的 progress2 在 ≤3.2.3 走 stderr、新版走 stdout，
  scp 走 stderr——两路 SplitParser 挂同一个 `\r` 解析器，认不出的行只攒作错误尾巴，
  终局一律以退出码判定。远端路径为 rsync 会原样拼进远端命令行，传输前做 shell 词转义
  （scp 默认 SFTP 协议按字面量处理，不转义）。

## 已在本机验证 / 未验证

验证过（`dms ipc`，2026-10-14）：无配置文件时创建只含托管区块的新文件（600 权限）；
添加/删除只动区块内文本、用户手写块逐字节保留；重名拒绝；BatchMode 探活失败原因转述；
`ps` 轮询识别/消失/`kill`；外部编辑与增删的竞态。

未在本机验证：真实远程主机的连接与密钥认证路径（需要可达主机）、密码认证交互（按设计走终端）、
ControlPersist master 的识别（需要开启连接复用）、popout 与 launcher 的视觉渲染与交互
（需要登录会话里人工打开）。有真实环境的朋友欢迎回报。

## 开发

```bash
ln -sfn "$PWD" ~/.config/DankMaterialShell/plugins/sshMan   # 在本插件目录内执行
dms ipc call plugins enable sshMan      # 首次：scan 后启用
dms ipc call plugin-scan reload sshMan  # 热重载入口；改 manifest 需先 plugin-scan rescan
qmllint *.qml
```

## 国际化

组件文案通过 `I18n.trFor("sshMan", ...)` 取译，中文译文在
[`translations/zh_CN.json`](translations/zh_CN.json)。新增文案请同时补键，
缺键时界面会退回英文原文。
