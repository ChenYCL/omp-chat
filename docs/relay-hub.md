# Relay Hub 协议 v1（跨网络：房间码配对，两端都向外拨号）

LAN 直连需要同网段。网易 UU 远程这类产品的做法是：**两端都主动连一台公网中继**，
用房间码找到彼此，中继做纯转发——不需要路由器开端口、不需要公网 IP。

OMPChat 采用同样的拓扑，但转发的是结构化会话状态而不是视频/输入事件。

```
 iPhone ──(房间码)──┐                    ┌──(房间码)── Mac
                    ↓                    ↓
              ┌───────────────────────────┐
              │   Relay Hub（公网，自建）   │
              │   房间：code → 两条通道     │
              └───────────────────────────┘
```

## 房间码

- 6 个字符，字母表 `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`（去掉易混的 `I O 0 1`）。
- Mac 端生成并持久化在 `AppSettings.relayRoomCode`；每次「开启远程控制」若为空则生成。
- iOS 端只输入房间码，不再需要 IP/端口/token。

## 四条路由（Hub 实现）

所有请求 `Content-Type: application/json`。Hub 只做转发，不解包业务字段。

### 1. 主机上行流（Mac → Hub）

`GET /v1/host/stream?room=CODE`

- Mac 打开并保持长连接。Hub 在该房间标记「主机在线」。
- Hub 通过此流下发指令：`event: command\ndata: {"kind":"input","conversationID":"…","text":"…"}\n\n`
  kind 取值见「客户端指令上行」。
- Hub 每 15 秒发 `: ping` 心跳。

### 2. 主机状态上行（Mac → Hub）

`POST /v1/host/state?room=CODE`，body 为整份 `RelaySnapshot` JSON（与 LAN 协议同结构）。

- Hub 保存每个房间最近一份状态并递增 `rev`，转发给所有在线客户端流。
- 无主机在线时返回 `409`。

### 3. 客户端状态下行流（iOS → Hub）

`GET /v1/client/stream?room=CODE`

- 连接即发 `event: hello\ndata: {"rev":N,"host":"…"}\n\n`。
- 主机状态更新时发 `event: rev\ndata: {"rev":M}\n\n`。
- 客户端收到更高 rev 后自行 `GET /v1/client/state?room=CODE` 拉全量。

### 4. 客户端指令上行（iOS → Hub）

`POST /v1/client/command?room=CODE`
body：`{"kind":"input","conversationID":"…"|null,"text":"…"}`、`{"kind":"stop","conversationID":"…"}`，或批准卡片答复
`{"kind":"approve","approvalID":"<RelayApproval.id>","decision":"allowOnce"|"deny","requestID":"<手机自定>"}`。

- Hub 转发到该房间的主机流；成功 `200 {"ok":true}`；无主机在线 `409`。
- `approve` 允许一次 / 拒绝 Mac 上等待批准的工具调用；`requestID` 缺省可省。手机没有
  `allowAlways`（持续放行留在 Mac 上决定）：Hub 校验 `approvalID` 非空、`decision` 只能是
  `allowOnce`/`deny`，其余 `400 {"error":"bad command"}`，不下发。
- Mac 拒绝时在下一份快照的 `commandFailures`（`requestID` + `error`）里回报，`error` 为
  `not_found`（卡片不存在或已处理）或 `shell_disabled`（非读取类调用需要 Mac 打开
  「允许手机访问文件与终端」）。
- 排队追问：`{"kind":"sendQueuedNow"|"removeQueued","conversationID":"…","queuedID":"<RelayQueuedMessage.id>"}`
  （立即发送 / 删除 Mac 上排队的追问，语义见 relay-protocol.md「排队的追问与压缩状态」）。Hub 校验
  `conversationID`、`queuedID` 都是非空字符串，否则 `400 {"error":"bad command"}`，不下发。

### 拉全量

`GET /v1/client/state?room=CODE` → `200 <RelaySnapshot>`；房间不存在/无状态 `404`。

## 安全边界（明确记录）

- 房间码是唯一凭证，6 字符 32 进制 ≈ 10.7 亿组合；Hub 对同一 IP 的失败配对限速（≥5 次/分钟则 429）。
- 传输默认 https（生产必须由 Caddy/Nginx 终结 TLS）。仓库内的参考实现是明文 HTTP，仅用于本机/内网联调。
- Hub 不持久化任何会话内容，只在内存保留最后一份快照与最近 200 条指令。
- 房间在主机断开 10 分钟后回收。

## Swift 侧契约

`OMPCore/Relay/RelayHubClient.swift`（新增）：

```swift
public final class RelayHubClient: @unchecked Sendable {
    public init(hubURL: URL, roomCode: String)
    /// Mac 侧：注册主机并开始消费指令。
    public func startHost(onCommand: @escaping @Sendable (RelayCommand) async -> Void) throws
    /// Mac 侧：推送一份完整快照。
    public func publish(_ snapshot: RelaySnapshot) async throws
    /// iOS 侧：连接并拿首帧状态。
    public func connectClient() async throws -> RelaySnapshot
    /// iOS 侧：rev-poke 流。
    public func revisions() -> AsyncStream<Int>
    /// iOS 侧：拉全量。
    public func snapshot() async throws -> RelaySnapshot
    /// iOS 侧：下发指令。
    public func send(_ command: RelayCommand) async throws
    public func stop()
}
```

`AppSettings` 新增（全部 `decodeIfPresent` 带默认）：
`relayHubURL: String = ""`、`relayRoomCode: String = ""`、
`remoteHubURL: String = ""`、`remoteRoomCode: String = ""`。

模式选择：`relayHubURL` 为空 = LAN 模式（现状）；非空 = Hub 模式（房间码）。

## 参考实现

`tools/relay-hub/relay_hub.py`（Python 3.12 标准库 asyncio，零依赖，约 200 行），
本机联调：`python3 tools/relay-hub/relay_hub.py --port 8899`。

部署到公网时前置 Caddy 反代并终结 TLS，只暴露 443。
