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
- `role` 只有小写 `user` / `assistant`；`streaming=true` 表示该消息仍在增量生成。

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
