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
