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
}
