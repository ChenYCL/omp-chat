# omp-ui：消息内原生界面

对标 ChatGPT 在回复里直接渲染可交互界面（卡片、指标、图表、标签页、按钮）。OMPChat 用 SwiftUI 原生渲染，Mac、iPhone 和手机远程会话页共用一个渲染器，不嵌网页、不执行脚本。

## 格式

模型在回复中输出 ```` ```omp-ui ```` 代码块，**每行一个 JSON 对象**：

```omp-ui
{"type":"card","id":"hero","title":"NEXUS","subtitle":"智能控制中心","icon":"cpu","badge":"在线","style":"dark"}
{"type":"metric","parent":"hero","label":"处理请求","value":"24.8K","delta":"+18.6%"}
{"type":"metric","parent":"hero","label":"响应延迟","value":"42ms","delta":"-12.3%","tone":"positive"}
{"type":"tabs","id":"t","options":["总览","任务"],"style":"segmented"}
{"type":"chart","parent":"t","tab":"总览","kind":"line","title":"运行分析","labels":["一","二","三"],"series":[{"name":"负载","values":[42,58,50]}]}
{"type":"list","parent":"t","tab":"任务","items":["部署 v2","回滚演练"]}
{"type":"button","label":"生成周报","send":"把上面的数据整理成周报","style":"primary"}
```

- 选择逐行格式是为了**边生成边渲染**：每写完一行，界面就多一个组件。最后一行在生成过程中通常不完整，会先忽略，不算错误。
- `id` + `parent` 组成树，父节点写在前面。父节点还没到的子节点暂时显示在顶层。
- 同一个 `id` 再写一行会原地替换，适合进度更新。
- 字段宽松：数值和字符串可以互换（`"value": 98.2` 与 `"value": "98.2"` 都可以）。
- 最多渲染 300 个节点，嵌套最多 8 层。

## 组件

| type | 主要字段 | 说明 |
|---|---|---|
| card | title subtitle icon badge style(`dark`) | 容器。`dark` 使用主色实底，子节点自动切换反色 |
| metric | label value delta tone icon | 相邻的 metric 自动排成网格 |
| text | text style(`title`/`headline`/`caption`) | 支持行内 Markdown |
| chart | kind(`line`/`bar`) title labels series | Swift Charts，多系列时显示图例 |
| table | columns rows | 复用 Markdown 表格样式 |
| tabs | options style(`segmented`) | 子节点用 `tab` 归属；没有 `tab` 的子节点在所有标签页都显示 |
| list | items icon | |
| progress | label progress(0–1) tone | |
| badge | text tone | |
| stack | style(`horizontal`) | 横向或纵向排列子节点 |
| divider | | |
| button | label send style(`primary`) | 点击后把 `send` 作为下一条用户消息发出；相邻按钮排成一行 |

`tone`：`positive` / `negative` / `warning` / `neutral`。没写时，`delta` 以 `+` 开头视为正向、`-` 开头视为负向。

## 行为

- 系统提示词末尾追加 `GenUIGuide.systemPrompt`，告诉模型何时使用以及组件清单。普通问答仍然用 Markdown。
- 按钮：Mac 和 iPhone 本地会话调用 `sendNow`；手机远程会话通过中继发 `input` 命令到同一个 Mac 会话。生成过程中点击无效。
- 无法识别的 `type` 不渲染。解析失败的完整行会在底部显示「N 行无法解析」，「查看源码」可以切换回原文。

## 代码

- 解析：`OMPCore/GenUI/GenUIDocument.swift`（单测 `GenUIDocumentTests`）
- 提示词：`OMPCore/GenUI/GenUIGuide.swift`
- 渲染：`OMPChatUI/GenUIView.swift`，在 `MarkdownText` 中遇到 `omp-ui` / `genui` 代码块时调用
