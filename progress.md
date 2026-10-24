# Progress

## 2026-10-24 · /ace-loop P1 队列清空（提交 3d276c5，已 push）

- p1-collapse-all ✅ 侧栏 Codex 菜单加「折叠全部分组 / 展开全部分组」，作用于项目与自定义分区
- p1-section-bulk ✅ 分区右键加「归档分区全部会话」（isArchived=true、取消置顶、逐条落盘）与「标记分区已读」
- p1-lightbox-paging ✅ 灯箱改为画廊模型：MediaAttachmentView 传入消息内全部图片 ref，左右悬浮箭头翻页、底部 n/total 胶囊、macOS ←/→ 键盘翻页、翻页重置缩放、复制/保存作用于当前图

验证：swift test 27/27 绿；macOS + iOS BUILD SUCCEEDED；覆盖安装 /Applications/OMPChat.app 运行中。
