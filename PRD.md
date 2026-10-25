# OMPChat PRD

> 原生 macOS + iOS AI 聊天客户端。一套 SwiftUI 代码（`OMPChatUI`）同时服务两端，
> 协议层走 OpenAI 兼容 / Anthropic 线格式，对接任意中转（ccLoad / one-api / OpenAI / Anthropic / Ollama）。
> 对标三套产品：**ChatGPT Desktop（2026-10 解包核实）**、**Codex Desktop**、**PaseoPro（iOS 实机录屏逐帧）**。

最后更新：2026-10-24，对应提交 `4d4f6ec`（`origin/main` 已同步，67 个提交）。

## 1. 产品定位

- 本地优先：会话、项目、设置全部落在本机工作区文档（`workspace.json`），不依赖云账号。
- 一个网关，全部模型：ccLoad 网关 290+ 模型，模型选择器按规模自动升级为可搜索面板。
- 双端同构：macOS 走 Codex 桌面布局，iOS 走 PaseoPro 移动布局，共享同一套数据与传输层。

## 2. 已交付能力（按模块）

### 2.1 会话与侧栏

| 能力 | 提交 | 对标 |
|---|---|---|
| 文件持久化、旧文档容错解码 | `f254878` | — |
| 置顶专区、时间分桶（今天/昨天/前7天/前30天/更早） | `91523c6` `5e35ba0` | ChatGPT sidebar |
| 项目分组（折叠文件夹行、右键新建/重命名/删除） | `bbc276a` `3307237` | Codex 项目行 |
| 自定义会话分区 | `48f1e87` | `sidebarElectron.customSections` |
| 归档 + 归档页关键词/项目过滤 | `48f399a` `aa49b78` | `archivedTasks.searchPlaceholder` / `projectFilter` |
| 锁定对话 + Touch ID / 密码解锁 | `755fb17` `9b7eb42` | ChatGPT locked chats |
| 临时对话（不落盘） | `e62a218` | `temporaryChat` |
| 拖拽排序 + 三种排序模式（更新/创建/手动） | `a31e5a6` `29d7690` | `sortMenu.updated/created/manual` |
| 标记已读 / 未读、后台流式菊花、未读蓝点 | `c80d316` `723b41c` | `markRead` / `markUnread` |
| 会话内搜索 ⌘F、自动命名、复制为新分支 | `31c6adb` `57ca6a0` `bf0aad6` | `forkActions` |
| 侧栏用量告警条（≥85% 橙、≥95% 红） | `4d4f6ec` | `sidebarElectron.usageAlert` |

### 2.2 对话与消息

- 实时 SSE 逐 token 流式（修掉 8KB 缓冲，实测 30–60ms 间隔）`4a9e9d5`
- 思考过程折叠、操作卡片、耗时、token 明细气泡 `95227ac` `d11a4e9`
- 重新生成版本历史（≤5）与用户提问版本分支 `< n/n >` `fd67efa` `4680c0d`
- 引用回复、消息多选批量操作、赞/踩反馈 `6346473` `a9e9149` `e62a218`
- 停止保留部分回复、会话级草稿隔离、↑↓ 多级输入历史 `57ca6a0` `d60d1ef` `bf0aad6`
- 朗读（语速 0.8x–1.5x、中/英/粤/日音色、朗读中可停止）`3056cd0` `7f2773a` `e387cde`
- 分享、导出（md / html 可打印 PDF / json）、JSON 导入 `3056cd0` `09f14a3` `02751af`
- 图片灯箱（捏合 + 按钮缩放、百分比、适应、复制、保存）`fa0a8e9` `4881c09`
- 生图 6 种艺术风格预设 `973b3f8`

### 2.3 富文本

- Markdown 表格（斑马纹、横向滚动、预览）`362e553`
- LaTeX `$$` 公式块 `3322306`
- 代码块：320pt 限高内滚、行号栏、折叠、Git diff 行高亮、复制为 Markdown、HTML/SVG 工件预览（WKWebView）`060ae9b` `e16135a` `7f0d7b5` `47bdb7e` `394b365`
- 消息内链接系统打开 `a31e5a6`

### 2.4 输入与命令

- Codex 输入卡：顶部工作区标签条、无聚焦绿框、深灰圆形发送键 `1f82a5d`
- Slash 命令（/review /fix /test /arch /opt /summary /translate）`91523c6`
- ⌘K 命令面板（动作 / 项目穿透 / 会话检索 / 主题切换）`108540f` `3f4a98d`
- 联网搜索开关、语音模式面板、角色预设 5 套 `362e553` `d11a4e9`
- 快捷键矩阵：⌘N ⇧⌘N ⇧⌘R ⌘. ⇧⌘V ⌘F ⌘K ⌘B ⌥↑ ⌥↓ ⌘, `8b884a5`
- 对话级自定义指令、推理强度（快速/平衡/深度）`38e74e9`

### 2.5 设置

- macOS 双栏设置壳（左导航 + 搜索 + 右卡片）：常规 / 外观 / 语音 / 已归档 / 键盘快捷键 / 会话排序 / 连接 / 关于 `24117aa`
- 供应商：测试连接与延迟、4 个新预设、百模型搜索面板 `a776de0` `f538dcc`
- 清除全部对话二次确认、在访达中显示数据文件 `7f2773a` `244bc90`
- 离线横幅（NWPathMonitor）、上下文容量气泡 `e524793` `34c0d75`

### 2.6 iOS（PaseoPro）

- 抽屉（搜索、流式菊花、未读蓝点、项目折叠）、聊天/主机分段 `adf8b27` `12dbcf8`
- 悬浮 chips（diff 统计、子代理）、滚底键、胶囊输入框 `752456b` `b90c2d1`
- 主机四态：文件（书签、源码查看器）、交互式终端（补全/历史/清屏）、脚本、配置 `8de31a5` `48927ee`
- 项目 / 会话历史 / 计划任务 / 用量 四大面板、可控设备面板、子代理面板 `6acc44d` `394b365`

### 2.7 局域网远程控制（吸收 collie/herdr 思路）

- macOS 主机端：`OMPCore/Relay`（`RelayModels` / `RelayServer` / `RelayAdvertiser`）+ `RelayHostController`。`NWListener` 起 HTTP，`GET /pair` `/snapshot` `/state`(SSE) `POST /input` `/stop`，全部校验 `X-OMP-Token`；`update()` 递增 rev 并向 SSE 广播；Bonjour 广告挂同一 listener（`_ompchat._tcp.`）
- 设置 → 远程控制：开关 / 端口 / 配对码复制 / 运行状态行；开关写入 `relayEnabled`，空 token 自动生成 UUID 持久化
- iOS 端：`RemoteRelayClient`（`URLSession.bytes` 逐行解析 SSE，断线 1s→5s 退避重连）+ `RemotePairSheet`（配对表单 → 主机会话列表 → 只读远程会话屏，可发送与停止）；主界面右下角天线按钮进入
- 协议文档 `docs/relay-protocol.md`；设计取舍：镜像结构化状态而非字符流/截屏，SSE 推 rev 后按需全量拉快照

### 2.8 手机端完整操控台（moshi / collie / herdr 的内核）

iPhone 不是只读镜像，而是能完成全部交互的远程控制台。所有动作都表达为 `RelayCommand`，
由 Mac 用自己的模型方法执行 —— 单一事实来源，手机不持有权威状态。

- 指令面 16 条：发送 / 停止 / 切换会话 / 新建 / 重命名 / 删除 / 重新生成 / 删除单条消息 /
  编辑重发 / 从消息分支 / 赞踩 / 切换模型 / 置顶 / 归档 / 锁定 / 标记未读
- 线格式 `RelayCommandWire`（扁平 JSON），LAN 服务端、中继、Python hub、双端共用同一份编码
- `RemoteConsoleScreen`：助手正文走画布 + 流式光标、用户气泡、长按操作菜单、状态 chips、
  流式感知输入条、顶栏菜单（重命名/重生成/置顶/归档/未读/删除）

### 2.9 跨网络（房间码 + 公网中继，对齐网易 UU 远程的拓扑）

- 两端都向外拨号到同一台中继，用 6 位房间码相遇：**不需要同一 Wi-Fi、不需要公网 IP、不开端口**
- `tools/relay-hub/relay_hub.py`：零依赖 asyncio 参考实现（主机流 / 状态上报 / 客户端流 /
  指令转发 / 房间回收 / 同 IP 配对限速）
- 设置 → 远程控制「跨网络」开关 + 中继地址 + 房间码（复制/换一个）；LAN 与中继**并行运行**
- 协议 `docs/relay-hub.md`；中继只转发结构化会话状态，不保存聊天内容

### 2.10 手机操作 Mac 的文件与终端（Host RPC）

- 「主机」页四个面板（文件/终端/脚本/配置）全部走真实 Mac：`info` / `fs.list` / `fs.read` / `exec` 四个 RPC，LAN `POST /rpc` 与中继 `/v1/client/rpc`（按 id 关联、130s 超时 504、主机掉线 409）
- 未配对或 Mac 未放行：统一空态，不展示任何演示数据
- 安全：设置 → 远程控制「允许手机访问文件与终端」**默认关闭**；关闭时 `exec` / `fs.*` 返回 `shell_disabled`；令牌或房间码门控；Mac 端保留最近 20 条操作记录
- 沙盒结论（签名探针实测）：仅 home-relative 例外能读文件但 `git` 失败；只有 `absolute-path.read-write = /` 能让登录 shell 的 git 正常。因此 macOS entitlements 含该临时例外——自签名本机构建，**不适合上架 App Store**
- 子进程 `HOME` 取 `getpwuid`（沙盒内 `NSHomeDirectory()` 是容器路径）
- 已知限制：手机侧 Ctrl-C 只取消等待，Mac 进程跑到超时（≤120s）；协议见 `docs/host-rpc.md`

## 3. 架构约束（不可破坏）

- 会话解码一律 `decodeIfPresent`，新增字段必须有默认值，旧 `workspace.json` 必须能打开。
- 密钥：数据保护钥匙串优先，ad-hoc 签名回退 `0600 secrets.json`。
- `OMPCHAT_STORE_DIR` 会被沙盒剥离，不能依赖环境变量定位存储。
- 传输层按 SSE 事件边界（换行）即时 yield，禁止重新引入大块缓冲。
- iOS 免费开发者账号设备上限 6 台，签名成功不等于能安装。
- 沙盒 App 必须声明 `com.apple.security.network.server` 才能监听端口；iOS 访问局域网必须有 `NSLocalNetworkUsageDescription` + `NSBonjourServices`。
- `RelayAdvertiser` 必须在 server 启动后懒取 listener，禁止在构造时缓存（会拿到 nil）。

## 4. 验证基线

- `cd Packages/OMPKit && swift test --jobs 4`：OMPCoreTests + OMPChatUITests 全绿（当前 46 个）。
- macOS 与 iOS Simulator 双端 `xcodebuild` 通过后，`ditto` 覆盖 `/Applications/OMPChat.app`。
- iOS UI 测试：`xcodebuild -scheme OMPChatiOS -destination 'platform=iOS Simulator,id=<UDID>' test`，7 个用例覆盖三 Tab / 抽屉 / 主机四态（含真实终端）/ 远程配对 / 发送与草稿 / 深色模式，截图导出到 `/tmp/ompchat-uitest-shots`。
- 每个功能一个提交，推送 `origin/main`（仓库已配置 `http.proxy` 走本机 7897）。

## 5. 演进路线（按优先级）

来源：2026-10-22 版 ChatGPT.app 解包（`app.asar` 598MB，`sidebarElectron` 316 个键）与官方设置页截图。

### P1 — 下一个迭代

| 项 | 官方键位 | 说明 |
|---|---|---|
| 侧栏全部折叠 / 展开 | `collapseFolder` / `expandFolder` | 一键折叠所有项目与分区 |
| 自定义分区批量归档 | `customSections.archiveAll` / `markRead` | 分区级批量操作 |
| 图片灯箱多图翻页 | `imagePreviewDialog.nextImage` | 需要消息内图片序列 |

### P2 — 设置页补齐

| 项 | 说明 |
|---|---|
| 个性化 / 记忆 | `settings.personalization`、`memory.enableMemories` |
| 外观自定义强调色 | `settings.appearance.customAccent` |
| 通知偏好 | `settings.nav.notifications` |
| Git 设置 | `settings.nav.git-settings`（默认分支、blame） |
| 数据控制 | 导出全部数据、存储占用统计 |

### P3 — 平台能力（依赖系统集成，单列评估）

- 权限模型：默认权限 / 完整访问权限开关（截图「常规 → 权限」）。
- 默认文件打开位置、菜单栏常驻、关闭窗口确认。
- Worktree 分叉：`forkIntoWorktree` / `continueIntoWorktree`。
- 侧边聊天分屏：`threadWorkspace.layout.splitView`。
- 计划任务真实调度：当前是 UI 面板，缺 cron 执行器。
- Mermaid 图表渲染：`codeBlock.mermaid`。

## 6. 明确不做

- 不造没有真实状态支撑的假开关（权限、菜单栏常驻等系统级能力在接上真实实现前不出现在设置里）。
- 不引入云账号体系；分享保持本地（系统分享面板 / 复制 Markdown）。
- 不改传输协议；新供应商只走现有 OpenAI 兼容 / Anthropic 适配器。
