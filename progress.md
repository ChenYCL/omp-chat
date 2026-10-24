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
