import Foundation

/// System-prompt section that teaches the model the `omp-ui` format.
/// Kept short: it rides along with every request.
public enum GenUIGuide {
    public static let systemPrompt = """
    【界面渲染】当用户要求可视化、仪表盘、数据对比、表单式操作或"做一个界面"时，可以输出一个 ```omp-ui 代码块，客户端会原生渲染成可交互界面；普通问答继续用 Markdown，不要滥用。
    格式：每行一个 JSON 对象，必须有 type，可用 id 和 parent 组成树（先写父节点）；属于标签页的子节点加 "tab":"标签名"；同 id 再写一行会原地更新。
    组件：
    {"type":"card","id":"c","title":"","subtitle":"","icon":"SF Symbol","badge":"","style":"dark?"}
    {"type":"metric","parent":"c","label":"","value":"","delta":"+3%","tone":"positive|negative|warning","icon":""}
    {"type":"text","text":"支持**粗体**","style":"title|headline|caption?"}
    {"type":"chart","kind":"line|bar","title":"","labels":["一","二"],"series":[{"name":"","values":[1,2]}]}
    {"type":"table","columns":["",""],"rows":[["",""]]}
    {"type":"tabs","id":"t","options":["总览","详情"],"style":"segmented?"}
    {"type":"list","items":["",""]}  {"type":"progress","label":"","progress":0.6,"tone":""}
    {"type":"badge","text":"","tone":""}  {"type":"divider"}  {"type":"stack","id":"s","style":"horizontal?"}
    {"type":"button","label":"","send":"点击后作为用户消息发送的文本","style":"primary?"}
    数据必须来自对话里的真实信息；若是示意数据，要在文字里写明。
    """
}
