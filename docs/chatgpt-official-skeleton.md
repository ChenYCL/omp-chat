# 官方 ChatGPT 桌面端解包结论（2026-10-22 版，app.asar 598MB）

来源：本机 `/Applications/ChatGPT.app`，解包至 `/tmp/chatgpt-asar-2026`。所有键位与数值均为 bundle 原文，非推测。

## 1. 真实 DOM 分层（CSS module 名）

```
MainContentSurface          画布（--color-surface）
└─ MainContentViewport      滚动容器
   ├─ MainContentTopFade    贴顶渐变遮罩，24pt
   └─ MainContentFrame      内容宽 --thread-content-max-width（48rem = 768）
PageSurfaceLayout / FullHeightPageSurfaceLayout

ComposerLayoutRoot          输入卡（--composer-radius = 4px×7 = 28）
├─ ComposerTopMenuPanel     上方浮层：工作区/项目胶囊
├─ ComposerLayoutBody
│  ├─ RichTextInput         富文本输入
│  └─ ComposerLayoutAttachments
└─ ComposerLayoutFooter     + / 🌐 / 模型胶囊 / ⚙ / 发送

MarkdownRoot（Paragraph / Heading / List / ListItem / Table / TableHeaderCell / Blockquote / Checkbox）
Material · Modal · MenuList · MenuItem · CheckMark · Workspace · ActivityText · LoadingResultsShimmer
```

**官方桌面端没有 52pt 图标轨**（`--app-menu-gutter: 0px`）。左侧就是一条 250–270px 侧栏，`sidebarElectron.rail` 只描述可重排的导航项（Chats / Chat / Plugins / Settings），不是竖排图标条。

## 2. 设计令牌（官方 CSS 实测，已落到 `OMPDesign/Theme.swift`）

### 颜色（light / dark）

| 语义 | 官方变量 | light | dark |
|---|---|---|---|
| 画布 | `--color-surface` | `#fff` | `#212121` |
| 次级表面（侧栏） | `--color-surface-secondary` | `#e8e8e8` | `#303030` |
| 三级表面（填充/用户气泡） | `--color-surface-tertiary` | `#f3f3f3` | `#414141` |
| 抬升表面 | `--color-surface-elevated` | `#fff` | `#000` |
| 正文 | `--color-text` | `#0d0d0d` | `#fff` |
| 次级文字 | `--color-text-secondary` | `#5d5d5d` | `#cdcdcd` |
| 三级文字 | `--color-text-tertiary` | `#8f8f8f` | `#afafaf` |
| 描边 | `--color-border` | `#0000001a` | `#ffffff26` |
| 重描边 | `--color-border-heavy` | `#00000026` | `#fff3` |
| 轻描边 | `--color-border-light` | `#0000000d` | `#ffffff0d` |
| 主按钮/发送键 | `--color-background-primary-solid` | `#0d0d0d` | `#f9f9f9` |
| 主按钮文字 | `--color-text-primary-solid` | `#fff` | `#0d0d0d` |
| hover 幽灵底 | `--color-background-primary-ghost-hover` | `#0000000d` | `#ffffff1a` |
| 链接/信息 | `--color-text-info` | `#3a83f7` | `#63a8f8` |

强调文字色（light/dark）：blue `#2451da`/`#b0c9fe`、cyan `#0b5c7c`/`#b3e3fc`、green `#055f51`/`#42dec2`、lime `#586c11`/`#d8f590`、magenta `#af1fa7`/`#fec5f6`、orange `#ab1616`/`#fdb9ab`、pink `#c31b74`/`#fbadca`、purple `#7e14d0`/`#c8a4fb`、yellow `#7d3f09`/`#fee096`、slate `#4a6e98`/`#acc7e8`。

Codex 代码高亮：keyword `#ab4f7a`/`#f8a6c8`、literal `#ac4f23`/`#f1a275`、string `#3a843f`/`#83d197`、variable `#643cae`/`#b897f4`、attribute `#b8802b`/`#f9dc78`、name `#1f4e94`/`#63a8f8`。

### 度量

| 令牌 | 值 |
|---|---|
| `--spacing` | 4px |
| `--height-token-row` | 36px |
| `--avatar-size` | 28px |
| `--thread-content-max-width` | 48rem = 768 |
| `--message-bubble-radius` | 22px |
| `--composer-radius` | calc(4px × 7) = 28 |
| `--radius-{sm,md,lg,xl,2xl,3xl,4xl}-base` | 6 / 8 / 10 / 12 / 16 / 20 / 24 |
| `--text-{xs,sm,base,lg,xl,2xl}` | 12 / 14 / 16 / 18 / 20 / 24 |
| `--leading-normal` / `--leading-relaxed` | 1.5 / 1.625 |
| `--shadow-lg` | `0 4px 8px -2px #0000001a` |
| `--shadow-xl-spread` | `0 0 0 .5px <border>, shadow-xl` |
| 字体 | sans `-apple-system, BlinkMacSystemFont, "Segoe UI"`；mono `ui-monospace, "SF Mono", Menlo` |

## 3. 功能骨架（i18n 键位实测，共 2979 条）

命名空间规模：`codex` 365、`sidebarElectron` 343、`settings` 232、`composer` 221、`chatgptConversations` 126、`sidebar` 84、`markdown` 58、`localConversation` 57、`threadHeader` 41。

### 侧栏（`sidebarElectron.*`）

- 结构：`rail`（可重排导航项 Chats / Chat / Plugins / Settings）、`priorityThreads`（活动视图）、`tasksSection`（Chats）、`unreads`（未读）、`pinnedThreads`、`archivedTasks`(24 键)、`customSections`(18 键)
- 活动视图 `priorityThreads`：`needsAttention`、`emptyState`「Nothing needs attention」、`markAllAsRead`、`refresh`「Clear read chats」、`showSection`（Chat / Work / Pinned / Scheduled）、`details.{chat,work,cloud,codex}`
- 组织方式：`groupByMenu.submenuTitle`「Organize sidebar」→ `By project` / `By connection`；`flatProjectSidebar.filter`（All / Chat / Work）；`sortMenu`（`updated_at` Last updated / `created_at` Created / `manual` Manual order）
- 行级操作：`pinThread` / `markRead` / `markUnread` / `archiveThread` / `renameDialog` / `deleteDialog` / `markReadError`
- 分区级：`customSections.*`（18）、`archiveProjectThreads.*`(12)、`archiveSelectedThreads.*`(6)
- 用量：`usageAlert`(12) + `usageAlert.cadence`(6) + `usageAlert.notifyOwner`(4)
- 连接：`connectionGroup`（Local / Cloud / Cloud (Legacy) / disconnectedNewThread / editConnection / remoteLoading）

### 顶栏（`threadHeader.*`）

`forkActions`「Fork」→ `forkIntoLocal` / `forkIntoSameWorktree` / `forkIntoWorktree`；`continueActions`「Continue in」→ 同三档；`copyActions`「Copy」→ `copyConversationMarkdown` / `copyAppLink` / `copyWorkingDirectory`；归档确认四态（普通 / 运行中 / 带定时任务 / 运行中带定时任务）。

### 输入框（`composer.*`）

`atMentionList`(41，含浏览器标签页提及 `browserTab.iabAriaLabel`)、`realtime`(33)、`dictation`(17)、`formatToolbar`(15：Bold/Italic/Heading1-3/段落/有序无序列表/链接)、`richLinkPopover`(12)、`mode`(10：用量额度剩余 day/hour/minute/weekly/monthly/annual)、`skillMentionList`(9)、`slashCommands`(5，带子菜单搜索)、`fileAttachment`(4)、`pastedTextAttachment`(5)、`contextButton`（`ariaLabel`「Add files and more」）、`modelPicker`、`threadGoal`

### 中间区（`thread.*`）

`sidePanel`：Browser / Files / Changes(diff) / Side chat / 多 tab（newTabToTheRight / duplicate / reload / rename / copyUrl / openInExternalBrowser）、`mergeRequestTab`（MR !{number}、PR #{number}）、`newTab.suggested`（Desktop / Terminal / New page）

### 设置（`settings.nav`，60 分区）

Account、General、Appearance、Keyboard shortcuts、Archived chats、Data controls、Model Providers、MCP servers、Hooks、Git、Environments、Cloud environments、Browser、Computer use、File viewers、Notifications、Usage、Import、Debug…（整机 232 条 settings 键位，含 `settings.automations.*` 定时任务的全部星期/摘要文案）

## 4. 与 OMPChat 的差距（本轮之后）

| 能力 | 官方键位 | OMPChat |
|---|---|---|
| 侧栏多 Tab 竖排轨 | `sidebarElectron.rail.*` | 已删图标轨，改官方单栏侧栏 |
| 活动视图（未读/进行中/待回复） | `priorityThreads.*` | 已做：侧栏与手机抽屉顶部「待处理」分区列出未读、正在生成、以及待回复（最后一条是用户发言或回复失败）的会话，带「全部标为已读」；无内容时隐藏，且不在下方列表重复。 |
| 组织方式 By project / By connection | `groupByMenu.*`、`flatProjectSidebar.filter` | 已做「整理侧栏」菜单：分组（按项目 / 按连接——按 provider 名分组，未知连接单列）与显示过滤（全部 / 聊天 = 未绑定目录 / 工作 = 绑定了目录），选择持久化，全部被过滤时显示「没有符合的对话」。 |
| 行级置顶/已读/归档/重命名/删除 | `pinThread`、`markRead`… | 已交付 |
| 分区批量归档 | `customSections.*`、`archiveProjectThreads.*` | 已交付 |
| 用量告警 | `usageAlert.*` | 已交付 |
| Fork / Continue in / Copy 三组顶栏菜单 | `threadHeader.*` | 已做：「分叉对话」三档（本地副本 / 同一工作目录 / 新建 Worktree，真跑 `git worktree add`）；「继续于」三档（改绑当前对话，不复制）；「复制」含 Markdown / 应用链接（`ompchat://thread/<uuid>`，双端已注册并可打开）/ 工作目录。绑定目录时标题旁显示路径胶囊，点按在访达中显示。设置 → Git 可选新 Worktree 的位置与分支名前缀。 |
| 富文本格式工具条 | `composer.formatToolbar.*` | 已做（写 Markdown 源码，不是所见即所得）：输入栏 B/I/U 按钮与「格式」菜单（⌘B 被侧栏占用，加粗用 ⇧⌘B；斜体 ⌘I、下划线 ⌘U）在草稿两端加/去标记，可叠加成 `***x***`；`Aa` 菜单与「格式」菜单里的标题 1–3 / 段落 / 无序 / 有序列表作用于草稿最后一段，链接包住整段草稿。限制：SwiftUI TextField 不暴露选区，作用范围是整段草稿；`MarkdownFormatting.toggle` 已接受选区参数，换成能报选区的输入控件即可只格式化选中文字。 |
| 用量额度剩余 | `composer.mode.rateLimit.*` | 未做（网关不返回额度头，无法诚实显示）；上下文容量气泡已有。 |
| 侧面板多 tab（Browser / Files / Changes / Side chat） | `thread.sidePanel.*` | 已做五个 tab（⌘J 或顶栏按钮，状态在模型里，可由 `/debug/action` 驱动）：终端真的跑 zsh（跟随线程目录），文件可进目录并看内容，改动分 已暂存 / 未暂存（git 的 XY 两列），可逐个或全部暂存 / 取消暂存、丢弃改动（先确认）、展开各自一侧的 diff，底部写提交信息提交（⌘↩），有上游且领先时推送（不强推、不设上游），git 的报错原样显示；旁聊就当前对话提问，主对话内容（最新的优先，约 2.4 万字以内）作为系统提示词，问答不写进对话、不落盘，「插入输入框」才会把回答交给主对话；浏览器是真实 WKWebView，多标签（新建 / 在右侧新建 / 复制 / 重命名 / 关闭，每个标签各留一个网页视图，切回不重载），地址栏 + 重新加载 / 复制网址 / 在默认浏览器中打开，本地地址用 http，其余裸域名用 https，带空格的当搜索。没做：`mergeRequestTab`（要登录 GitHub/GitLab）与 `newTab.suggested`。 |
| 设置 · 用量 / 导入 | `settings.nav` Usage、Import | 已做：用量分区（累计、7 / 30 天、14 天柱状图、用量最多的对话、按对话模型），推理 token 计在输出里（实测 20 条回复推理都不超过输出），手机用量面板用同一份统计；数据控制里「导入 JSON 对话…」读单个对话的导出文件。 |
| 代理运行时：工具调用 + 批准 + 权限模式 | Codex approval modes（只读 / 自动 / 完全访问）、`thread.approval*` | 已做（仅 macOS）：模型可调用内置 `read_file` / `list_dir` / `write_file` / `edit_file` / `shell`、MCP 工具和技能，一条消息内最多 25 轮模型调用。每次调用按风险（读取 / 修改文件 / 运行命令 / 控制电脑）和对话的权限模式（只读 / 每次询问 / 自动 / 完全访问）决定直接运行、拒绝或弹批准卡片（允许一次 / 本次会话始终允许 / 拒绝）；读写工作目录以外的路径按运行命令处理；控制电脑永远逐次询问。停止键同时终止正在跑的工具进程树并拒绝等待中的卡片。工具默认在绑定了工作目录的对话里开启，输入栏「工具与权限」可改。工具只在 Mac 上运行；手机本身不调用工具，但手机发起的消息可以让 Mac 的模型调用工具（批准见下一行）。命令运行在应用沙盒里，新建的脚本不能直接执行，系统提示词已告诉模型改用解释器。 |
| 手机批准 Mac 的工具卡片 | 移动端 approvals | 已做（局域网与房间码两条路）：Mac 上等着批准的卡片随快照同步到手机，会话列表给该会话标「待批准」，进会话后卡片在对应调用下：风险标题、摘要、可展开的参数（超过 4 KB 截断并标明）、允许一次 / 拒绝，答复期间按钮置灰。手机永远给不了「始终允许」（400）。写文件 / 运行命令 / 控制电脑这类卡片，只有 Mac 上打开了「允许手机访问文件与终端」手机才能「允许」，否则按钮置灰并说明，「拒绝」始终可用；被拒的答复原因（`shell_disabled` / `not_found`）经快照回到手机。同一开关还限制手机发起的回复：关着时，对话即使是「自动」或「完全访问」，手机发起的回复也按「每次询问」走，卡片留在 Mac 上批。`/debug/*` 只接受本机连接，手机不能用它给自己开权限。实机验证（模拟器配对真实 Mac，真模型）：关着时手机看到卡片、允许置灰、点拒绝后卡片消失且文件没写；打开后点允许，Mac 上文件写出（`scenario_remote_approval.py` 36 项 + 两次模拟器点按）。 |
| MCP 服务器 | `settings.nav` MCP servers、`mcp_servers` 配置 | 已做（仅 macOS）：自写 MCP 客户端（stdio 与 Streamable HTTP，协议 2025-06-18，兼容 2025-03-26 / 2024-11-05），崩溃自动重启 3 次，设置里看状态、工具开关、stderr 日志，可手填或粘贴 Claude / Cursor / Codex 三种格式的 JSON 导入，密钥进钥匙串。一键目录 7 个开源服务器，版本全部钉死：Playwright、Filesystem、Fetch、Git、Memory、Sequential Thinking、Chrome DevTools。实机（`scenario_mcp_catalog.py`）在沙盒应用里把 7 个都从零安装并连上，工具数与记录一致（25 / 14 / 1 / 12 / 9 / 1 / 32），移除后没有残留进程。沙盒里新下载的包带隔离标记、脚本不能直接执行，`npx` / `uvx` 因此起不来（之前能连上只是因为缓存是在沙盒外预热的）；现在 App 自己用 `npm install --prefix` 装进应用目录、以 `node <入口>` 运行，uv 包用 `uvx --from <包> python -c <入口>`，规则在 `MCPPackageLaunch`。不是 `npx -y 包` / `uvx 包` 这两种写法的配置原样启动。没做：协议 2026-07-28（去掉了 initialize）、远程服务器的自定义请求头。 |
| 插件 / 技能 / AGENTS.md / 钩子 | Codex plugins（`plugin.json`、`skills/`、`.mcp.json`）、`settings.nav` Hooks | 已做（仅 macOS）：按 Codex 公开格式装插件（本地文件夹或 git 地址，安装前列出要运行的命令并确认，路径逃逸拒绝）；技能按 Codex 渐进披露只列名字和说明，正文由模型自己读；工作目录到仓库根的 AGENTS.md 拼进提示词；插件钩子 PreToolUse / PermissionRequest / PostToolUse 按 Codex 的退出码与 JSON 规则执行，默认关闭，需对每个插件单独「信任此插件的钩子」。实机验证 AGENTS.md 与技能都生效。与 Codex 的差别：同名技能只留离工作目录最近的一个；不读 `~/.codex/AGENTS.md`（由「自定义指令」承担）；没有插件市场；其余钩子事件只解析、本应用不触发；钩子按插件整体信任，任何钩子改动都要重新信任。 |
| 电脑控制 | `settings.nav` Computer use | 已做（VPS Docker 沙盒，实机端到端验证完成）：在 netcup VPS 部署隔离的 Docker Linux 桌面（Xvfb 1280×800 + openbox + GTK 应用 + AT-SPI + open-computer-use 1.3.0），通过 SSH 隧道转发至本机 127.0.0.1:8766，由 OMPChat 的 nc 桥接 stdio 接入 MCP。设置 → 电脑控制 顶部卡片展示沙盒状态（实时探测已连接 14 个工具，截图 166）。真实模型调用 list_apps 触发「控制电脑」逐次询问审批卡片（截图 167），批准后容器内通过 AT-SPI 读取到 gtk3-demo-application，模型在回复中成功整理为 Markdown 表格展示（截图 168）。所有动作只影响虚拟桌面，完全不碰本机窗口与隐私。旧的原生条目降级保留并注明本机沙盒 spawn EPERM 限制；详见 `docs/computer-use.md`。 |
| Mermaid | `codeBlock.mermaid` | 已做：原生渲染 flowchart/graph 与 sequenceDiagram（`MermaidDocument` 解析，`MermaidView` 用 Canvas 画箭头；循环边绕到框图外侧走虚线）。其余类型仍显示源码，不猜。 |
| 定时任务 | `inbox.automations.*`、`settings.automations.*`、`sidebarElectron.addAutomation` | 已做（应用内调度，仅 macOS）：侧栏「定时任务」分区与编辑器，计划有 一次 / 每天 / 工作日 / 周末 / 每周几 / 每 N 小时 / 每 N 分钟（下限 5 分钟），摘要与下次运行文字对齐官方（「每天 09:30」「明天 09:30」「未安排」）。每次运行新建对话（以任务名加时间命名）或发到指定对话（Codex 的 heartbeat），可带工作目录与权限。应用关着或休眠错过的时段，下次启动或唤醒只补跑一次；同一时段不会跑两次；过期的一次性任务要先改时间才能继续。只在 OMPChat 开着时运行；手机上没有入口，运行出的对话照常同步到手机。实机由应用自己的计时器触发验证过（`scenario_wave5.py --live`）。原来那个读 crontab 的假面板仍然删着。没做：会话行上的「定时任务运行 / 已附加定时任务」标记。 |
| 撤销提示 | `appUndo.*` | 已做：归档 / 取消归档、整个分区归档、置顶、改名、移入移出项目或分区、手动排序、新建 / 改名 / 删除分区、项目改名与删除、移除输入框附件之后，底部出现「已归档「…」 撤销」提示，6 秒后消失（悬停暂停）。撤销只还原这次动作改过的字段，目标已删除时说明「无法撤销：…」。删除对话不做撤销（本来就二次确认）。手机发来的操作不在 Mac 上登记撤销。⌘Z 只在没有文字输入框聚焦时生效，不抢输入框自己的撤销。实机 21 项（`scenario_undo.py`）。 |
| 运行中插话（steering）与上下文压缩 | `codex.composer.queuedSteerDuringCompaction`、`responseError.unansweredSteering` | 已做：回复进行中再发消息不再打断，而是排队，显示在输入框上方（立即发送 / 编辑 / 删除）；代理在两轮模型调用之间把它作为用户消息送进同一个回复，等批准时先排着。停止后排队保留但停住，只能手动发；重启也一样。送达后没被回答的追问下方注明。压缩上下文：+ 菜单「压缩上下文」、`/compact`，以及请求估算到窗口 85% 时自动压缩；保留最近两轮原文，更早的换成一段摘要，工具调用与结果不会被拆开；对话里的消息全部保留，分隔线可展开摘要。摘要不比原文短时不采用，保留原文并说明。压缩时发的消息等压缩完再发。手机控制台也能看到并操作排队。 |
| 文件引用 / 在…中打开 / 用 Codex 审查 | `markdown.fileReference.*`、`fileViewer.openInAnotherApp`、`codeReview.menu.review`、`codeReviewPlugin.manualReview.*` | 已做：助手消息里的文件路径（相对工作目录、绝对、`~`，可带 `:行`、`:行:列`、`#L行`）存在时显示为链接，点击在侧面板文件标签打开并滚到该行，右键：打开文件 / 在访达中显示 / 拷贝路径 / 拷贝文件内容（超过 1 MB 拒绝）/ 打开方式。顶栏工作目录旁「在…中打开」：访达、终端、iTerm2、VS Code、Cursor、Xcode 等已装应用，记住上次用的。「用 Codex 审查」：收集已暂存 + 未暂存 + 未跟踪的改动（约 80 KB 上限，超出列出省略的文件），开一个只读、开工具、绑定同一目录的「审查：…」对话，顶部注明结论只在这个对话里；没有改动时不开。实机：对埋了除零 bug 的改动审查，回答点名 `stats.py`。 |
| 工具与权限单选 | Codex 的 Chat / Agent / Agent (full access) | 已做：输入栏一个单选（跟随默认 / 仅聊天 / 只读 / 每次询问 / 自动 / 完全访问），按钮显示实际生效的那一项。原来是「允许使用工具」与「权限」两个独立设置，没有工作目录时选权限只改了一半，出现按钮写「仅聊天」却勾着「完全访问」，已修。 |
| 输入框听写 | `composer.dictation.*`、`dictation.*` | 已做（双端）：输入框麦克风按钮（⇧⌘V），听写栏显示时长、真实音量、实时文字、当前语言，可停止 / 取消 / 转写并发送；全程本机识别，音频不上传（macOS 26 / iOS 26 用 SpeechAnalyzer + DictationTranscriber，不需要语音识别授权；更早的系统用 SFSpeechRecognizer 并强制本机识别，没有本机模型的语言直接说「这台设备不支持听写」）。结果并进草稿，不覆盖已写的字；最长两分钟。错误文案对齐官方（无法开始听写 / 无法识别这段录音 / 没听清 / 打开麦克风权限才能听写…），识别失败可重试保留的录音或把已听到的文字加进消息。设置 → 语音 → 听写语言（跟随系统时，首选英文但地区在中国大陆 / 港澳台 / 新加坡且也设了中文，就用中文）。原来只有动画的「语音模式」面板已删除。实机：`say` 生成的中英文音频经同一识别器转写正确，静音 / 文件不存在 / 不支持的语言给出原因（`scenario_dictation.py`）。真实麦克风录音没在后台测，第一次使用会弹麦克风授权。 |
| 会话行状态标签 | `codex.localTaskRow.*` | 已做：桌面侧栏、手机抽屉和手机远程列表的会话行在标题后显示 等待批准 / 需要你处理 / 系统错误 / 定时任务运行 / 已附加定时任务；阻塞类只显示最高的一个，任务类随后；回复进行中不显示「需要你处理」「系统错误」。等待批准和需要你处理的会话进「待处理」。定时任务相关的行右键可「打开定时任务」。实机在插话与定时任务场景里逐步核对。 |
| 提及：`@` 文件 / 对话 / 标签页、`$` 技能 | `composer.atMentionList.*`、`composer.skillMentionList.*` | 已做（桌面）：输入 `@` 列出工作目录里的文件（遵守 `.gitignore`，跳过 `node_modules`、构建目录和隐藏目录）、对话和侧面板浏览器标签页；输入 `$` 列出仓库 / 用户 / 插件技能，并标出来源。选中后输入框显示可读的 `@名称`，上方有可删的标签；名称被改动后就变回普通文字。发送时读取内容，作为这条消息的附加上下文（文件 64 KB；对话取最近 20 条，16 KB；标签页正文 32 KB；技能 SKILL.md 32 KB；整条消息 128 KB 封顶，截断处有说明）。已删除、二进制、工作目录外的文件变成「提及说明」，不挡发送。气泡只显示用户写的字，附上的内容显示为标签，点开可看。原来的 `@` 只把标题当文字插进去，对模型没有作用，已替换。实机：关掉工具后，四种提及各自把只有那里才有的暗号送到了模型（`scenario_mentions.py` 35 项）。没做：手机输入框的提及选择、手机远程控制台里的附件标签。 |
