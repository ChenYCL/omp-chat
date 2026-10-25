# Host RPC 协议 v1（手机驱动 Mac 的真实文件系统与 shell）

手机上的「主机」页（文件 / 终端 / 脚本 / 配置）不读 iPhone 沙盒，也不展示任何演示数据。
未配对时界面是诚实的空态。配对之后，每一次列目录、读文件、跑命令都是一次
**Host RPC**：请求从手机出发，经 LAN `RelayServer` 或公网 `RelayHub`，由 Mac 上的
`HostExecutor` 在本机执行，再把结果原路返回。

```
 iPhone ── HostRPCRequest ──► LAN POST /rpc          ──► Mac onRPC ──► HostExecutor
        ◄── HostRPCResponse ──                      ◄──
 iPhone ── HostRPCRequest ──► Hub POST /v1/client/rpc ──► host SSE event: rpc
        ◄── HostRPCResponse ── Hub 挂起 ≤130s       ◄── POST /v1/host/rpc-result
```

## 类型

定义在 `OMPCore/Relay/RelayHostRPC.swift`，全部 `Codable & Sendable & Equatable`。
日期走 `RelayDate`（ISO8601，可带小数秒）。

```swift
public struct HostRPCRequest {
    public var id: String
    public var op: String          // "info" | "fs.list" | "fs.read" | "exec" | "exec.cancel" | "exec.poll"
    public var path: String?
    public var command: String?
    public var cwd: String?
    public var maxBytes: Int?
    public var timeout: Double?
    public var requestID: String?  // exec.cancel / exec.poll: the exec's id
    public var background: Bool?   // exec: answer "started" and keep running
    public var offset: Int?        // exec.poll: bytes the caller already has

public struct HostFSEntry { public var name: String; public var isDirectory: Bool; public var size: Int?; public var modified: Date? }
public struct HostInfo { public var hostName: String; public var user: String; public var home: String; public var cwd: String; public var gitBranch: String?; public var gitDirty: Int? }
public struct HostRPCResponse {
    public var stdout: String?; public var stderr: String?; public var exitCode: Int?
    public var cwd: String?; public var info: HostInfo?
    public var nextOffset: Int?    // exec.poll: cursor for the next poll
    public var done: Bool?         // exec.poll: true once the run finished
}
```

`error` 取值：`shell_disabled` | `not_found` | `timeout` | `cancelled` | `bad_request` | `unsupported`，或自由文本。

## 语义
- `info` 始终允许。`path` / `cwd` 省略时用 home；返回该目录的 git 分支与 dirty 计数。
- `fs.list` / `fs.read` / `exec` **仅当**主机设置 `AppSettings.relayAllowShell == true`（默认 false）
  才执行，否则 `ok: false, error: "shell_disabled"`。这是远程 shell 的唯一开关，默认关闭。
- `exec` 跑 `/bin/zsh -lc <command>`，工作目录 `cwd`（默认 home）。超时默认 30s，上限 120s。
  stdout / stderr 各自截断到 256 KB，截断时 `truncated: true`。
- `exec.cancel` 受同一个 `relayAllowShell` 开关限制，body 里 `requestID` 是在跑的
  `exec` 的 `id`。主机 SIGINT 掉该进程树（先子进程后包装 shell，2 秒后仍未退出再
  SIGKILL），被取消的 `exec` 以 `ok: false, error: "cancelled"` 返回，携带已产出的
  stdout / stderr 与 `exitCode: 130`。`requestID` 不存在或已结束：`ok: true,
  text: "not_running"`（幂等，重发无害）。iOS 上的执行器不跑命令，回答
  `ok: false, error: "unsupported"`。
- `exec` 带 `background: true` 时不等命令结束：立刻回答 `ok: true, text: "started"`，
  进程按请求 `id` 登记，继续跑。输出靠 `exec.poll` 取：body 带 `requestID`（那次 exec
  的 `id`）和 `offset`（调用方已经拿到的字节数，首次传 0）。回答 `ok: true`，`text`
  是自 `offset` 以来新增的输出（stdout 与 stderr 按到达顺序合并，分块边界按 UTF-8
  字符切，不会切开一个多字节字符），`nextOffset` 是下次该传的偏移，`done` 表示是否
  结束。`done: true` 时同时带 `exitCode` 和 cd 跟踪后的 `cwd`。未知 id：
  `ok: false, error: "not_found"`。单次运行的输出缓冲上限 1 MB，超出丢弃最旧的字节并
  回答 `truncated: true`。结束后的运行保留 60 秒可继续 poll，之后回收。
  `exec.cancel` 对后台运行同样有效，下一次 poll 看到 `exitCode: 130, done: true`。
  不带 `background` 的 `exec` 行为不变。iOS 上 `exec.poll` 与 `exec` 一样回答
  `unsupported`。

## 传输

### LAN

`POST /rpc`，header `X-OMP-Token`（与其它路由相同，缺失或不匹配 `401`）。
body 是 `HostRPCRequest` JSON，响应是 `HostRPCResponse` JSON。
**`ok: false` 也是 HTTP 200**——业务错误在 body 里，不在状态码里。

`RelayServer.onRPC` 未设置时回答 `ok: false, error: "unsupported"`。

### Hub

房间码仍是唯一凭证，限速规则不变。

1. 客户端 `POST /v1/client/rpc?room=CODE`，body 为 `HostRPCRequest`。
   Hub 按 `id` 建一个 asyncio future，把请求写成主机流上的
   `event: rpc\ndata: <json>\n\n`，然后**挂起这条 HTTP 连接**，最长 130 秒。
2. 主机收到事件，执行后 `POST /v1/host/rpc-result?room=CODE`，body 为 `HostRPCResponse`。
   Hub 按 `id` 找到 future 并完成它，客户端拿到 `200` + 该 JSON。
3. 无主机在线，或主机在等待期间断开：`409`。挂起的 future 在断开时全部取消。
4. 130 秒没有结果：`504`。
5. `op` 不在 `info | fs.list | fs.read | exec | exec.cancel | exec.poll`：`400`（Hub 拒绝未知操作，不转发给主机）。
6. 每个房间同时挂起的 RPC 上限 32，超出 `429`。`exec.cancel` 和 `exec.poll` **不受这个上限约束**：
   房间满载时照样转发，否则取消和读取会被自己人堵死。
7. 手机终端的 Ctrl-C 先发 `exec.cancel`（带在跑命令的 `id`），再取消本地等待；
   收到 `cancelled` 后徽章显示 `130 已取消`，已打印的部分输出保留。

## Swift 客户端

`RelayRPCSink`（`OMPCore`）是两种传输的共同接口：

```swift
public protocol RelayRPCSink: Sendable {
    func call(_ request: HostRPCRequest) async throws -> HostRPCResponse
}
```

- `RemoteRelayClient`（LAN，`OMPChatUI`）`POST /rpc`。
- `RelayHubClient`（`OMPCore`）`POST /v1/client/rpc`。`startHost` 增加可选参数
  `onRPC`（默认 `nil`，已有调用方不用改）：

```swift
public func startHost(
    onCommand: @escaping @Sendable (RelayCommand) async -> Void,
    onRPC: (@Sendable (HostRPCRequest) async -> HostRPCResponse)? = nil
) throws
```

主机侧 `RelayHubClient` 收到 `event: rpc` 后调用 `onRPC`，并把返回值 POST 到
`/v1/host/rpc-result`。`onRPC` 为 `nil` 时该事件被忽略（客户端会等到 504）。
