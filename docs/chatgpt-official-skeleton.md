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
| 活动视图（未读/进行中/待回复） | `priorityThreads.*` | 未做 |
| 组织方式 By project / By connection | `groupByMenu.*`、`flatProjectSidebar.filter` | 有项目分组，无连接分组与 All/Chat/Work 过滤 |
| 行级置顶/已读/归档/重命名/删除 | `pinThread`、`markRead`… | 已交付 |
| 分区批量归档 | `customSections.*`、`archiveProjectThreads.*` | 已交付 |
| 用量告警 | `usageAlert.*` | 已交付 |
| Fork / Continue in / Copy 三组顶栏菜单 | `threadHeader.*` | 有分叉与复制 Markdown，缺 worktree 三档 |
| 富文本格式工具条 | `composer.formatToolbar.*` | 未做（输入框是纯文本） |
| 用量额度剩余 | `composer.mode.rateLimit.*` | 只有上下文容量气泡 |
| 侧面板多 tab（Browser / Files / Changes） | `thread.sidePanel.*` | 未做 |
| Mermaid | `codeBlock.mermaid` | 已做：原生渲染 flowchart/graph 与 sequenceDiagram（`MermaidDocument` 解析，`MermaidView` 用 Canvas 画箭头；循环边绕到框图外侧走虚线）。其余类型仍显示源码，不猜。 |
| 定时任务真实调度 | `settings.automations.*` | 只有 UI 面板 |
