# Progress

## 2026-10-24 · /ace-loop P1 队列清空（提交 3d276c5，已 push）

- p1-collapse-all ✅ 侧栏 Codex 菜单加「折叠全部分组 / 展开全部分组」，作用于项目与自定义分区
- p1-section-bulk ✅ 分区右键加「归档分区全部会话」（isArchived=true、取消置顶、逐条落盘）与「标记分区已读」
- p1-lightbox-paging ✅ 灯箱改为画廊模型：MediaAttachmentView 传入消息内全部图片 ref，左右悬浮箭头翻页、底部 n/total 胶囊、macOS ←/→ 键盘翻页、翻页重置缩放、复制/保存作用于当前图

验证：swift test 27/27 绿；macOS + iOS BUILD SUCCEEDED；覆盖安装 /Applications/OMPChat.app 运行中。

## 2026-10-24 · /ace-loop P2 队列清空（提交 2a04748，已 push）

- p2-personalization ✅ 设置「个性化」：全局自定义指令拼在系统提示词后（对话级留空时生效）+ 记忆开关
- p2-accent-color ✅ 「外观」六色圆点强调色，写入 accentColorHex，双端根视图 .tint 即时生效
- p2-notifications ✅ 「通知」开关，流式完成且用户不在该会话时经 UNUserNotificationCenter 发本地通知
- p2-data-controls ✅ 「数据控制」：会话/消息/媒体计数、存储目录体积、NSSavePanel 导出全部 JSON

验证：swift test 27/27 绿；macOS + iOS BUILD SUCCEEDED；覆盖安装运行中。

## 2026-10-25 · 局域网远程控制（提交 e844147，已 push）

吸收 collie/herdr「桌面状态镜像到手机原生操作」思路，但镜像结构化会话状态而非字符流/
截屏：Mac 起 LAN HTTP + SSE，iPhone 原生浏览与发言。

- OMPCore/Relay：RelayModels / RelayServer（NWListener 手写 HTTP，五路由全 token 校验，命令串行）
  / RelayAdvertiser（Bonjour，挂 server 同一 listener——macOS 禁止同端口双 listener）
- RelayHostController + ChatAppModel.relaySnapshot()/handleRelayCommand()，快照节流 0.5s（流式 1s）
- 设置 → 远程控制：开关 / 端口 / 配对码复制 / 状态行
- iOS RemoteRelayClient + RemotePairSheet：配对 → 主机会话列表 → 只读会话屏（可发送与停止）
- 双端权限补齐：macOS network.server；iOS NSLocalNetworkUsageDescription + NSBonjourServices

排障实录：①RelayAdvertiser 构造时取 listener 得到 nil → 改懒取；②沙盒缺 network.server 无法监听；
③`URLSession.AsyncBytes.lines` 吞掉 SSE 空行分隔符，客户端永远拿不到事件 → 客户端与测试统一改
字节流喂 SSEParser；④bootstrap 双 .task 竞态导致读默认设置 → 共享 Task 等待。
验证：46/46 单测绿、双端 BUILD SUCCEEDED、实机 /pair 200、无 token 401、SSE hello+rev、
POST /input → Mac 真实经 ccLoad 生成「收到」并回读。
