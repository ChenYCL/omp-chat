# OMPChat Relay 协议 v1（局域网远程控制，吸收 collie/herdr「桌面镜像到手机原生操作」思路）

> 设计取舍：collie 靠 1s 轮询字符流做到"原生操控感"。我们不截屏、不传字符流，
> 直接镜像**结构化会话状态**，传输用 LAN HTTP + SSE 推 rev-poke + 快照拉取（比 1s 盲轮询更实时且省电）。
> 单一 token 鉴权；不做云端中继；不做端到端加密（LAN 内，token 足够，明确记录）。

## 传输

- HTTP/1.1，`NWListener`（Network.framework，仓库零依赖），默认端口 `8790`。
- Bonjour 服务类型 `_ompchat._tcp.`，TXT 记录 `ver=1`。
- 鉴权：所有请求带 `X-OMP-Token: <token>`；不匹配 → `401`。token 由 macOS 端首次开启时生成 UUID 持久化。
- 首次配对：`GET /pair`（带 token 头）→ `200 {"ok":true,"host":"<设备名>","rev":N}`。

## 状态快照

`GET /snapshot` → `200` JSON：

```json
{
  "rev": 42,
  "host": "MacBook Pro",
  "selectedID": "UUID字符串或null",
  "conversations": [
    {
      "id": "UUID字符串",
      "title": "标题",
      "updatedAt": "2026-10-25T12:00:00Z",
      "project": "项目名或null",
      "isStreaming": false,
      "messages": [
        {"id": "UUID字符串", "role": "user|assistant", "text": "正文", "ts": "...", "streaming": false}
      ]
    }
  ]
}
```

- `messages` 每会话只带最近 100 条；日期用 ISO8601。

## 活动与思考（v1 增量字段，向后兼容）

2026-10 起快照里的 assistant 消息新增两个**可选**字段，老客户端/Python hub 不识别即忽略，快照里没有这两个字段时行为与 v1 完全一致：

```json
{
  "id": "UUID字符串",
  "role": "assistant",
  "text": "正文",
  "ts": "...",
  "streaming": false,
  "thinking": "模型思考文本（≤ 8192 UTF-8 字节，空则整个字段不出现）",
  "activity": [
    {
      "id": "ToolCall.id",
      "name": "edit_file",
      "summary": "已编辑 AppDelegate.swift",
      "status": "running|ok|error",
      "added": 12,
      "removed": 3,
      "detail": "参数 + 输出原文（≤ 4096 UTF-8 字节，仅最近 5 条 assistant 消息携带；summary-only 行整个字段不出现）"
    }
  ]
}
```

语义：

- `activity` 每条消息最多 **50** 条（超出从尾部丢弃，保留最早的调用）；空数组与 `thinking` 为空字符串时**整个字段不编码**。
- `summary` 与桌面端 ActivityRow 同一套解析：已读 `<file>` / 已搜索 `<query>` / 已运行 `<cmd>` / 已编辑 `<file>`，未知工具回退原始名。
- `status`: 工具调用尚未返回 = `running`；返回且未标错 = `ok`；`isError` = `error`。手机端据此渲染橙色 spinner / 绿勾 / 红叉。
- `added` / `removed`: 对工具输出按行统计 `+`/`-` 前缀（忽略 `+++`/`---`），即桌面端 diff chip 同款数字；无 diff 时两字段都不出现。
- `detail` 是 `ToolCall.argumentsJSON` 与 `ToolResult.outputText` 用换行拼接的原文（都非空才拼接），UTF-8 字节级截断、不切开多字节字符。快照由 hub 整体重发，为控制流量**只有每会话最后 5 条 assistant 消息带 detail**，其余只有 summary 行。
- Swift 侧：`RelayMessage.thinking`（上限 `RelayMessage.maxThinkingBytes = 8192`）与 `RelayMessage.activity: [RelayActivity]?`（上限 `RelayActivity.maxPerMessage = 50`、`RelayActivity.maxDetailBytes = 4096`），全部 `decodeIfPresent` 解码，缺失即 `nil`。填充在 `ChatAppModel.relaySnapshot()`，渲染在 `RemoteConsoleScreen`（思考行 + 「N 个操作」折叠组，26pt 行高 / 13pt 文本 / 官方 diff 色）。

## 实时通知（SSE）

`GET /state` → `text/event-stream`：

- 连接建立立即发 `event: hello\ndata: {"rev":N}\n\n`。
- 主机端任何状态变化 rev+1，向所有连接广播 `event: rev\ndata: {"rev":M}\n\n`。
- 客户端收到 rev 大于本地 → `GET /snapshot` 全量拉取后替换。15s 无变化发心跳注释行 `: ping`。
- 客户端断线重连：直接重新 `/snapshot` + `/state`。

## 指令（手机 → Mac）

- `POST /input` `{"conversationID":"UUID或null","text":"..."}` → `{"ok":true,"conversationID":"UUID"}`。
  `null` 表示在 Mac 上新建对话发送。主机端串行执行，复用 `ChatAppModel.sendNow`。
- `POST /stop` `{"conversationID":"UUID"}` → `{"ok":true}`，等价于主机端 `stop()`。

## Swift 命名契约（双端必须一致）

OMPCore/Relay/（全部新文件）：

- `RelayModels.swift`：`public struct RelaySnapshot: Codable, Sendable`（`rev: Int, host: String, selectedID: String?, conversations: [RelayConversation]`）；
  `RelayConversation`（`id, title, updatedAt: Date, project: String?, isStreaming: Bool, messages: [RelayMessage]`）；
  `RelayMessage`（`id, role, text, ts: Date, streaming: Bool`）；日期统一 `ISO8601DateFormatter`。
- `RelayServer.swift`：`public final class RelayServer`：`start(port: UInt16, token: String) throws` / `stop()` /
  `update(_ snapshot: RelaySnapshot)`（内部 rev+1 并广播）/ `var onInput: (@Sendable (RelayCommand) async -> Void)?` /
  `var port: UInt16`。`public enum RelayCommand: Sendable { case input(conversationID: String?, text: String); case stop(conversationID: String) }`。
  手写极简 HTTP 解析（请求行 + 头 + Content-Length body），SSE 用长连接写流。
- `RelayAdvertiser.swift`：`public final class RelayAdvertiser`：`start(name: String, port: UInt16)` / `stop()`，基于 `NWListener.service` 注册。

OMPChatUI/：

- `RemoteRelayClient.swift`（iOS 用，亦可 mac 用）：`public final class RemoteRelayClient`：
  `init(host: String, port: UInt16, token: String)`、`func connect() async throws -> RelaySnapshot`、
  `func revisions() -> AsyncStream<Int>`、`func snapshot() async throws -> RelaySnapshot`、
  `func send(text: String, conversationID: String?) async throws`、`func stop(conversationID: String) async throws`。
  SSE 解析用 `URLSession.bytes`。
- `RelayHostController.swift`（macOS 用）：`public final class RelayHostController`：持有 `ChatAppModel` 弱引用，
  `start()/stop()`、`private(set) var isRunning: Bool`、`var lastError: String?`；定时/事件驱动把模型转成快照 `server.update`。

ChatAppModel 新增公共接口（由 macOS 端实现，iOS 端只消费不实现）：

- `public func relaySnapshot() -> RelaySnapshot`
- `public func handleRelayCommand(_ command: RelayCommand) async`

## 分工边界（防文件冲突）

- Core agent：只新建 `OMPCore/Relay/*`，不碰任何现有文件。
- macOS agent：只碰 `RelayHostController.swift`（新）、`ChatAppModel.swift`、`ProviderSettingsView.swift`（设置里加「远程控制」分区：开关/端口/token 显示复制/状态行）、`Apps/macOS/OMPChatApp.swift`（装配）。
- iOS agent：只碰 `RemoteRelayClient.swift`（新）、iOS 端远程屏（`iOSChrome.swift` 或新 `RemotePairSheet.swift`）、`Apps/iOS/OMPChatiOSApp.swift`。**不碰** ChatAppModel/ProviderSettingsView/OMPCore 现有文件。

## 明确不做

云端中继、TLS、多主机同时镜像、消息级 delta 合并（rev-poke + 全量快照已够快）、Windows/Android。
