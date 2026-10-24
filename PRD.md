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

## 3. 架构约束（不可破坏）

- 会话解码一律 `decodeIfPresent`，新增字段必须有默认值，旧 `workspace.json` 必须能打开。
- 密钥：数据保护钥匙串优先，ad-hoc 签名回退 `0600 secrets.json`。
- `OMPCHAT_STORE_DIR` 会被沙盒剥离，不能依赖环境变量定位存储。
- 传输层按 SSE 事件边界（换行）即时 yield，禁止重新引入大块缓冲。
- iOS 免费开发者账号设备上限 6 台，签名成功不等于能安装。

## 4. 验证基线

- `cd Packages/OMPKit && swift test`：27 个单测全绿。
- macOS 与 iOS Simulator 双端 `xcodebuild` 通过后，`ditto` 覆盖 `/Applications/OMPChat.app`。
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
