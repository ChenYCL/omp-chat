# 诊断

macOS 和 iOS 共用一套诊断：内存里的实时事件日志、落盘的 JSONL，以及一组真正发探测的健康检查。凭据（API Key、配对码、房间码、`Authorization` 头）在进入内存、磁盘、日志和任何 HTTP 路由之前都会被遮罩。

## 事件日志

`DiagnosticsCenter.shared` 记录 `category / level / message / fields`：

- 内存环形缓冲 500 条，序号单调递增；
- 同步镜像到 `os.Logger`（subsystem `com.ace.ompchat`）；
- 追加到 `<存储目录>/diagnostics/events.jsonl`，超过 1 MB 轮转为 `events.1.jsonl`，只保留一份旧文件。

已埋点：中继启动/停止/错误与客户端连接、每次 Host RPC（op、耗时、ok/error，命令截断到 80 字符）、聊天流的开始、首 token 延迟、结束/错误（供应商 host、模型、HTTP 状态）、工作区加载与保存失败、iOS 配对成功/失败。事件不含消息正文。

## 健康检查

`设置 → 诊断`（macOS）或抽屉里的「诊断」（iOS）里点「运行诊断」。每项返回 `ok / warn / fail / skip`，`skip` 一定带原因：

| 检查 | 探测 |
| --- | --- |
| 供应商 | 对已配置供应商的 models 路径发一次真实请求，报告往返耗时 |
| 工作区文档 | 从磁盘解码 `workspace.json` |
| 存储目录 | 真实写入一次并删除，报告剩余磁盘 |
| 中继监听 | 连接 `127.0.0.1:<端口>` |
| 配对凭据 | 配对码/房间码是否存在（只显示遮罩后的前后缀） |
| 公网中继 | 未配置时 skip；配置了就 GET 该地址 |
| 手机访问文件与终端 | 读取该开关的真实状态 |
| 用户主目录 / 登录 shell 的 git | 仅 macOS；iOS 上 skip |
| 已配对主机 / 快照新鲜度 | 仅 iOS；macOS 上 skip |

## 从 shell 实时调试

中继开着时，两条路由和其它路由一样要求 `X-OMP-Token`，否则 `401`。**所有 `/debug/*` 路由只接受本机（回环地址）连接**，别的机器——包括配对了的手机——一律 `403 {"error":"loopback_only"}`：这些路由能发消息、批准工具调用、装 MCP 服务器、跑 git，令牌又和手机的是同一个，不限制来源就等于绕开了「允许手机访问文件与终端」。远程看日志要先 ssh 到这台 Mac 上再 curl。

```bash
curl -s -H "X-OMP-Token: $TOKEN" "http://127.0.0.1:8795/debug/events?since=0"
curl -s -H "X-OMP-Token: $TOKEN" "http://127.0.0.1:8795/debug/report"
```

`/debug/events?since=<seq>` 返回序号大于 `since` 的事件，用来增量追日志；`/debug/report` 现场跑一遍全部检查并返回 JSON 报告。

不走 HTTP 时直接 tail JSONL。macOS 存储目录是
`~/Library/Containers/com.ace.ompchat/Data/Library/Application Support/OMPChat`
（未沙盒运行时是 `~/Library/Application Support/OMPChat`）：

```bash
tail -f "$HOME/Library/Containers/com.ace.ompchat/Data/Library/Application Support/OMPChat/diagnostics/events.jsonl"
```

模拟器里先定位容器再 tail：

```bash
CONTAINER=$(xcrun simctl get_app_container booted com.ace.ompchat.ios data)
tail -f "$CONTAINER/Library/Application Support/OMPChat/diagnostics/events.jsonl"
```

`OMPCHAT_STORE_DIR` 会同时改存储目录和这份日志的位置。

## 后台截图（ompshot）

OMPChat 自己把窗口画成 PNG（`NSView.cacheDisplay`），不读屏幕像素，所以：应用在后台、被别的窗口挡住也能截；截图里只可能有 OMPChat 自己的窗口，不会带进别的应用；不需要「屏幕录制」权限。前提是 设置 → 远程控制 已打开（复用中继和它的令牌）。

```bash
python3 tools/ompshot/ompshot.py windows                      # 列出窗口编号、类型、尺寸
python3 tools/ompshot/ompshot.py snap -o .artifacts/shots/x.png  # 主窗口
python3 tools/ompshot/ompshot.py snap -w 36510 -o y.png          # 指定窗口（表单、弹层各是一个窗口）
```

令牌依次取 `--token`、`$OMP_RELAY_TOKEN`、应用自己的 `secrets.json`（`relay-host.token`），不会打印出来。底层是两条路由，同样要求 `X-OMP-Token`：

| 路由 | 返回 |
| --- | --- |
| `GET /debug/windows` | `{"windows":[{number,title,kind,width,height,visible,main,key}]}`；`kind` 为 window / sheet / popover / panel |
| `GET /debug/snapshot?window=<编号>` | `image/png`；不带 `window` 时取主窗口（应用在后台时 `mainWindow` 为空，退而取最大的可见标题窗口）。编号不是数字 `400`，没有这个窗口 `404` |

限制：

- 打开中的菜单（`NSMenu`）不在应用的窗口列表里，截不到；弹层（popover）和表单（sheet）是单独的窗口，可以按编号截。
- 只在 macOS 上提供；iOS 应用上这两条路由返回 `503`。模拟器本来就能在后台截：`xcrun simctl io booted screenshot x.png`。
- 对照系统按窗口截图（`screencapture -l <编号>`），内容和布局一致，只有约 0.05% 的像素在文字、图标边缘的抗锯齿上略有差别。

## 后台驱动（/debug/action、/debug/state）

黑盒测试不靠模拟点击：动作走的是菜单本身调用的模型方法，应用留在后台。两条路由同样要求 `X-OMP-Token`；动作名或参数不认识返回 `400`，宿主没装钩子返回 `503`，动作本身失败返回 `200` 加 `{"ok":false,"error":"…"}`。省略 `conversationID` 的动作作用于当前选中的对话。

```bash
python3 tools/ompshot/ompshot.py state
python3 tools/ompshot/ompshot.py act setGoal --goal 发布前补齐文档
python3 -I tools/ompshot/scenario_codex.py      # 跑完整场景，0 失败才退出 0
python3 -I tools/ompshot/scenario_codex.py --live   # 另外让旁聊向真实供应商提一个问题
python3 -I tools/ompshot/scenario_agent.py         # 代理运行时：工具、批准、AGENTS.md、MCP，全程调用供应商
```

| 动作 | 字段 | 对应的界面操作 |
| --- | --- | --- |
| `select` | `conversationID` | 侧栏点一行 |
| `newChat` | — | 新聊天 |
| `sidePanel` | `open`（布尔），可选 `tab` = terminal / files / changes / sideChat / browser | ⌘J、侧面板标签 |
| `openSettings` / `closeSettings` | `openSettings` 可选 `section`（设置侧栏的分区名：general / usage / dataControls / git …） | 应用菜单 设置…（⌘,）；按窗口是否可见判断 |
| `setDraft` | `text` | 在输入框里输入 |
| `format` | `style` = bold / italic / underline / heading1–3 / paragraph / bulletedList / numberedList / link | B / I / U 与 Aa 菜单 |
| `setGoal` | `goal`（空白即清除），可选 `conversationID` | 设定目标 |
| `sidebar` | `grouping` = project / connection 和/或 `filter` = all / chat / work，至少一个 | 整理侧栏 |
| `markAllRead` | — | 待处理 → 全部标为已读 |
| `setUnread` | `conversationID`、`unread`（布尔） | 行菜单 标为未读 / 已读 |
| `continueIn` | `mode` = local / folder / worktree；folder 需要 `path`（必须是已存在的目录） | 顶栏 继续于 |
| `fork` | `mode` = local / sameWorktree / worktree | 顶栏 分叉对话（分叉后选中副本） |
| `openLink` | `url`（`ompchat://thread/<UUID>`） | 系统打开应用链接 |
| `delete` | `conversationID` | 行菜单 删除 |
| `dismissError` | — | 错误提示条的 × |
| `git` | `op` = stage / unstage（要 `paths`，非空字符串数组）、stageAll / unstageAll、discard（要 `path`）、commit（要 `message`，空白由宿主拒绝）、push；可选 `conversationID` | 侧面板 改动：勾选暂存、丢弃改动、提交、推送。在对话绑定的工作目录里执行，没绑定就报错 |
| `browserOpenTab` | 可选 `url`（缺省首页）、`rightOf`（标签 id，缺省加到末尾） | 浏览器 + / 在右侧新建标签页 |
| `browserCloseTab` / `browserDuplicateTab` / `browserSelectTab` | `tabID` | 标签的 × / 复制标签页 / 点标签 |
| `browserRenameTab` | `tabID`、`title`（空串清掉自定义名） | 重命名… |
| `browserNavigate` | `tabID`、`url`（必须是完整地址；地址栏的搜索与补 https 规则只在界面里） | 地址栏回车 |
| `sideChat` | `text`，可选 `conversationID` | 侧面板 旁聊 发送；空问题返回 ok:false 和原因 |
| `clearSideChat` / `stopSideChat` | `clearSideChat` 可选 `conversationID` | 旁聊 清空 / 停止 |
| `send` | `text`，可选 `conversationID` | 输入框发送。立即返回，不等回复结束（回复可能停在批准卡片上）。这个对话正在回复或压缩时，消息进排队（`selected.queued`），不打断；别的对话正在回复时拒绝（`另一个对话正在回复`），和桌面输入框一样 |
| `queued` | `queuedID`（`selected.queued[].id`）、`op` = sendNow / edit / delete，可选 `conversationID` | 排队气泡的 立即发送（打断当前回复，马上发）/ 编辑（放回输入框）/ 删除 |
| `compact` | 可选 `conversationID` | 压缩上下文（+ 菜单与 `/compact`）。等压缩结束才返回；失败时 `error` 是界面上的原因 |
| `stop` | — | 停止键 / ⌘.：同时终止正在跑的工具、拒绝所有等待中的卡片 |
| `approve` | `approvalID`（`state.pendingApprovals[].id`）、`decision` = allowOnce / allowAlways / deny | 批准卡片的三个按钮；控制电脑类的 allowAlways 按一次处理 |
| `setPermissionMode` | `mode` = readOnly / ask / auto / full，缺省或 null 跟随设置默认；可选 `conversationID` | 输入栏 工具与权限 菜单 |
| `setToolsEnabled` | `enabled`（布尔），缺省或 null 为自动（绑定了工作目录才开）；可选 `conversationID` | 同上 |
| `setAccess` | `access` = default / chat / readOnly / ask / auto / full，可选 `conversationID` | 输入栏「工具与权限」单选：一次写好「开不开工具」和「权限」两项，菜单勾的就是按钮上写的 |
| `sidebarOp` | `op` = toggleArchive / togglePin / rename（`title`）/ move（`groupID`，缺省或 null 为移出分组）/ createSection（`name`）/ renameGroup（`groupID`、`name`）/ deleteGroup（`groupID`）/ archiveSection（`groupID`）；对话类可选 `conversationID` | 会话行、项目、自定义分区的右键菜单；都会登记撤销 |
| `undo` / `dismissUndo` | — | 撤销提示条的「撤销」/ 关掉提示条。`undo` 只撤最新的一条；目标已不在时返回 `{"ok":false,"error":"无法撤销：…"}`，那条也随之出栈 |
| `scheduledTask` | `op` = add（`title`、`prompt`、`schedule`、可选 `target` / `workingDirectory` / `permissionMode`）/ pause / resume / delete / runNow（`taskID`） | 侧栏 定时任务 与编辑器。`schedule`、`target` 用工作区文件里同样的 JSON（例如 `{"kind":"daily","hour":9,"minute":30}`、`{"kind":"once","date":"2026-10-28T01:00:00Z"}`、`{"kind":"attached","conversationID":"…"}`）；字段不合法时 `error` 是编辑器自己的提示 |
| `openFile` | `path`，可选 `line`（从 1 起的整数） | 消息里文件引用的「打开文件」：侧面板文件标签打开并滚到该行 |
| `codeReview` | 可选 `conversationID` | 用 Codex 审查：给该对话的工作目录开一个只读的审查对话；没有改动、没有目录时返回原因 |
| `mcpInstall` | `entryID`（`MCPCatalog.entries` 的 id）、可选 `values`（每个输入项一个字符串数组） | 设置 → MCP 服务器 → 目录 → 安装；电脑控制服务器不在目录里，只能从 设置 → 电脑控制 加 |
| `mcpRemove` | `serverID` | MCP 服务器行的删除（连同钥匙串里的密钥） |
| `setWebSearch` | `enabled`（布尔） | 输入栏 联网 胶囊 |
| `computerUseAdd` | 可选 `serverID`（缺省为主选） | 设置 → 电脑控制 → 添加，**但不弹确认单**，只给黑盒用：由 `scenario_computer_use.py --allow-handshake` 调用，只握手不调用工具，跑完用 `mcpRemove` 移除 |
| `setPhoneAccess` | `enabled`（布尔） | 设置 → 远程控制 → 允许手机访问文件与终端。只在本机回环连接上可用，手机不能用它给自己开权限；`scenario_remote_approval.py` 用它测开 / 关两种情况并还原 |

浏览器的重新加载、复制网址、在默认浏览器中打开要用到活的网页视图，不在动作里。

`GET /debug/state` 返回（键按字母排序）：`selectedID`、`selected`（`id / title / goal / workingDirectory / messageCount / hasUnread / isPinned / isArchived / groupID / sideChat / permissionMode / toolsEnabled / access / accessLabel / lastReply / isCodeReview / reviewOutcome / queued / isCompacting / compaction / transcript`；`sideChat` 是 `role / text / status / error` 列表；`lastReply` 是最后一条用户消息之后的整段回复，一轮代理回复跨好几条助手消息，`toolCalls` 按顺序列出其中每次调用的 `id / name / arguments / result / isError`，`text` 取最后一条；`access` 是「工具与权限」菜单勾选项，`accessLabel` 是按钮上写的；`reviewOutcome` 为 running / reported / unreported；`queued` 是排队的追问 `id / text / held`，`held` 表示被停止或重启停住、只能手动发；`compaction` 是 `summary / coveredThroughID / tokensBefore / tokensAfter`；`transcript` 是全部消息的 `id / role / text`（前 400 字）`/ status / error`）、`draft`、`conversationCount`、`unreadIDs`、`priorityIDs`、`sidebarGrouping`、`sidebarFilter`、`webSearchEnabled`、`phoneAccess`、`undoToast`（`message / offersUndo`）、`undoHistory`（还能撤销的动作，最新在前）、`groups`（项目与自定义分区，`id / name / isSection / conversationIDs`）、`scheduledTasks`（`id / title / status / summary / nextRunLabel / nextRunAt / runCount / lastRunConversationID / lastSkipReason / running`，日期为 ISO-8601）、`pendingFileRequest`（文件标签还没取走的打开请求）、`sidePanelOpen`、`sidePanelTab`、`sideChatStreaming`、`errorMessage`、`isStreaming`、`pendingApprovals`（`id / conversationID / callID / toolName / source / risk / summary`）、`runningToolCallIDs`、`mcpServers`（`id / name / origin / enabled / status / toolCount / detail / tools`，`status` 为 disabled / needsRuntime / connecting / ready / failed，`detail` 是缺的运行时或失败原因加 stderr 末尾）、`browserTabs`（`id / title / url / selected`）、`settingsOpen`、`windowTitles`（只含可见窗口）。值为空的可选键不出现在 JSON 里，脚本要用 `.get`。

`scenario_codex.py` 只在自己新建的对话和临时 git 仓库（带一个本地 bare「上游」）里操作，结束时删掉它们，并把选中项、侧栏设置、侧面板、浏览器标签和原有的未读标记都还原。`--live` 是唯一会调用供应商的部分。

其余场景脚本同样只动自己建的对话、分区、任务和临时目录，跑完删除并还原选中项：

| 脚本 | 内容 | 调用模型 |
| --- | --- | --- |
| `scenario_undo.py` | 改名、置顶、归档、移入移出分区、删除带对话的分区、整个分区归档后逐个撤销；目标已删除时撤销给出原因 | 否 |
| `scenario_wave5.py` | 定时任务新建 / 校验 / 暂停 / 继续 / 删除，打开文件到指定行，审查在没有改动 / 没有目录时拒绝；`--live` 再测到点自动运行、发到当前对话的立即运行、对埋了 bug 的改动审查 | `--live` 时 |
| `scenario_steer.py` | 等批准时插话排队并在同一个回复里送达、停止后排队被停住、编辑放回输入框、立即发送打断、压缩上下文与压缩时插话 | 是 |
| `scenario_agent.py` / `scenario_remote_approval.py` | 代理运行时与手机批准 | 是 |
| `scenario_mcp_catalog.py` | 7 个目录 MCP 服务器在沙盒里从零安装并连上 | 否（要下载包） |
