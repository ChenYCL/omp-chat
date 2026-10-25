import XCTest
@testable import OMPCore

final class GenUIDocumentTests: XCTestCase {
    func testBuildsTreeFromParentLinks() {
        let doc = GenUIDocument.parse("""
        {"type":"card","id":"c","title":"NEXUS","style":"dark"}
        {"type":"metric","parent":"c","label":"处理请求","value":"24.8K","delta":"+18.6%"}
        {"type":"metric","parent":"c","label":"可用率","value":98.2}
        {"type":"text","text":"根节点"}
        """)
        XCTAssertEqual(doc.roots.map(\.type), ["card", "text"])
        let metrics = doc.children(of: "c")
        XCTAssertEqual(metrics.map(\.label), ["处理请求", "可用率"])
        XCTAssertEqual(metrics[1].value, "98.2", "numbers are accepted where strings are expected")
        XCTAssertEqual(doc.roots[0].style, "dark")
        XCTAssertTrue(doc.invalidLines.isEmpty)
    }

    func testUnfinishedLastLineIsPendingNotInvalid() {
        // Mid-stream the final line is cut off; it must not be reported.
        let doc = GenUIDocument.parse("""
        {"type":"text","text":"一"}
        {"type":"chart","kind":"li
        """)
        XCTAssertEqual(doc.nodes.count, 1)
        XCTAssertTrue(doc.invalidLines.isEmpty)
    }

    func testBrokenMiddleLineIsReportedAndSkipped() {
        let doc = GenUIDocument.parse("""
        {"type":"text","text":"一"}
        not json
        {"text":"missing type"}
        {"type":"divider"}
        """)
        XCTAssertEqual(doc.nodes.map(\.type), ["text", "divider"])
        XCTAssertEqual(doc.invalidLines, [2, 3])
    }

    func testSameIdReplacesInPlace() {
        let doc = GenUIDocument.parse("""
        {"type":"progress","id":"p","label":"部署","progress":0.2}
        {"type":"text","text":"中间"}
        {"type":"progress","id":"p","label":"部署","progress":"0.9"}
        """)
        XCTAssertEqual(doc.nodes.map(\.id), ["p", "line-2"])
        XCTAssertEqual(doc.nodes[0].progress, 0.9)
    }

    func testOrphanAndSelfParentRenderAsRoots() {
        let doc = GenUIDocument.parse("""
        {"type":"text","id":"a","parent":"not-yet","text":"x"}
        {"type":"text","id":"b","parent":"b","text":"y"}
        """)
        XCTAssertEqual(doc.roots.map(\.id), ["a", "b"])
        XCTAssertTrue(doc.children(of: "b").isEmpty, "a node is never its own child")
    }

    func testChartSeriesAndTableCellsDecodeLeniently() {
        let doc = GenUIDocument.parse("""
        {"type":"chart","kind":"BAR","labels":["一","二"],"series":[{"name":"负载","values":[42,"58.5"]},{"name":"B","data":[1,2]}]}
        {"type":"table","columns":["名称","数值"],"rows":[["a",1],["b",2.5]]}
        """)
        let chart = doc.nodes[0]
        XCTAssertEqual(chart.kind, "bar")
        XCTAssertEqual(chart.series?.map(\.values), [[42, 58.5], [1, 2]])
        XCTAssertEqual(doc.nodes[1].rows, [["a", "1"], ["b", "2.5"]])
    }

    func testNodeCountIsCapped() {
        let source = (0..<(GenUIDocument.maxNodes + 20))
            .map { #"{"type":"text","text":"\#($0)"}"# }
            .joined(separator: "\n")
        XCTAssertEqual(GenUIDocument.parse(source).nodes.count, GenUIDocument.maxNodes)
    }

    func testLanguageTag() {
        XCTAssertTrue(GenUIDocument.isGenUILanguage("omp-ui"))
        XCTAssertTrue(GenUIDocument.isGenUILanguage("GenUI"))
        XCTAssertFalse(GenUIDocument.isGenUILanguage("json"))
        XCTAssertFalse(GenUIDocument.isGenUILanguage(nil))
    }

    // MARK: Form state

    func testFormDefaultsPerType() {
        let doc = GenUIDocument.parse("""
        {"type":"input","id":"name","label":"名字","placeholder":"输入"}
        {"type":"input","id":"city","value":"上海"}
        {"type":"toggle","id":"urgent","value":true}
        {"type":"slider","id":"days","min":1,"max":14,"value":30}
        {"type":"slider","id":"ratio","min":0,"max":1,"step":0.1,"value":"0.3"}
        {"type":"select","id":"level","options":["低","中","高"],"value":"不存在"}
        {"type":"text","id":"t","text":"不是表单"}
        """)
        XCTAssertEqual(doc.formDefaults, [
            "name": "", "city": "上海", "urgent": "true",
            "days": "14", "ratio": "0.3", "level": "低",
        ], "滑块越界要夹到范围内，选择项不在列表里时取第一项，非表单节点不计入")
        XCTAssertEqual(doc.nodes[0].placeholder, "输入")
        XCTAssertEqual(doc.nodes[3].min, 1)
        XCTAssertEqual(doc.nodes[3].max, 14)
    }

    func testFillSubstitutesKnownFieldsAndKeepsUnknownOnes() {
        let values = ["name": "张三", "days": "3"]
        XCTAssertEqual(
            GenUIDocument.fill("给 {{name}} 请 {{ days }} 天假，抄送 {{boss}}", values: values),
            "给 张三 请 3 天假，抄送 {{boss}}",
            "未知占位符原样保留，方便看出模板写错"
        )
        XCTAssertEqual(GenUIDocument.fill("没有占位符", values: values), "没有占位符")
        XCTAssertEqual(GenUIDocument.fill("半个 {{name", values: values), "半个 {{name", "未闭合的占位符原样保留")
    }

    func testNumberFormattingFollowsStep() {
        XCTAssertEqual(GenUIDocument.formatNumber(3, step: nil), "3")
        XCTAssertEqual(GenUIDocument.formatNumber(0.30000000004, step: 0.1), "0.3")
        XCTAssertEqual(GenUIDocument.formatNumber(2.5, step: 0.5), "2.5")
    }

    func testToggleOptionsWordTheTemplateValue() {
        let doc = GenUIDocument.parse("""
        {"type":"toggle","id":"urgent","options":["否","是"]}
        {"type":"toggle","id":"plain"}
        {"type":"input","id":"reason","value":"true"}
        """)
        let values = doc.templateValues(["urgent": "true", "plain": "true", "reason": "true"])
        XCTAssertEqual(values["urgent"], "是")
        XCTAssertEqual(values["plain"], "true", "没写 options 的开关保持原值")
        XCTAssertEqual(values["reason"], "true", "非开关字段不受影响")
        XCTAssertEqual(doc.templateValues(["urgent": "false"])["urgent"], "否")
    }
}
