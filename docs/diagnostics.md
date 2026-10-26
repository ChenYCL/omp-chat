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

中继开着时，两条路由和其它路由一样要求 `X-OMP-Token`，否则 `401`：

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

浏览器的重新加载、复制网址、在默认浏览器中打开要用到活的网页视图，不在动作里。

`GET /debug/state` 返回（键按字母排序）：`selectedID`、`selected`（`id / title / goal / workingDirectory / messageCount / hasUnread / sideChat`，`sideChat` 是 `role / text / status / error` 列表）、`draft`、`conversationCount`、`unreadIDs`、`priorityIDs`、`sidebarGrouping`、`sidebarFilter`、`sidePanelOpen`、`sidePanelTab`、`sideChatStreaming`、`errorMessage`、`browserTabs`（`id / title / url / selected`）、`settingsOpen`、`windowTitles`（只含可见窗口）。

`scenario_codex.py` 只在自己新建的对话和临时 git 仓库（带一个本地 bare「上游」）里操作，结束时删掉它们，并把选中项、侧栏设置、侧面板、浏览器标签和原有的未读标记都还原。`--live` 是唯一会调用供应商的部分。
