import XCTest
@testable import OMPCore

final class MermaidDocumentTests: XCTestCase {
    func testFlowchartNodesEdgesAndLabels() throws {
        let source = """
        flowchart LR
          A[开始] --> B{判断}
          B -->|是| C((结束))
          B -.-> D(重试)
        """
        let doc = try XCTUnwrap(MermaidDocument.parse(source))
        guard case .flowchart(let chart) = doc.diagram else { return XCTFail("应是流程图") }
        XCTAssertEqual(chart.direction, .leftRight)
        XCTAssertEqual(chart.nodes.map(\.id), ["A", "B", "C", "D"])
        XCTAssertEqual(chart.nodes.map(\.label), ["开始", "判断", "结束", "重试"])
        XCTAssertEqual(chart.nodes.map(\.shape), [.box, .diamond, .circle, .rounded])
        XCTAssertEqual(chart.edges.count, 3)
        XCTAssertEqual(chart.edges[0].from, "A")
        XCTAssertEqual(chart.edges[0].to, "B")
        XCTAssertEqual(chart.edges[1].label, "是")
        XCTAssertTrue(chart.edges[2].dashed, "点线箭头要标成虚线")
    }

    func testBareScopeDeclaresNodesWithoutEdges() throws {
        let doc = try XCTUnwrap(MermaidDocument.parse("graph TD\n  A\n  B[Settle]"))
        guard case .flowchart(let chart) = doc.diagram else { return XCTFail("应是流程图") }
        XCTAssertEqual(chart.direction, .topDown)
        XCTAssertEqual(chart.nodes.map(\.label), ["A", "Settle"], "裸节点用 id 当文字")
        XCTAssertTrue(chart.edges.isEmpty)
    }

    func testSequenceParticipantsAndMessages() throws {
        let source = """
        sequenceDiagram
          participant C as 手机
          participant S as Mac
          C->>S: 打开文件
          S-->>C: 内容
        """
        let doc = try XCTUnwrap(MermaidDocument.parse(source))
        guard case .sequence(let sequence) = doc.diagram else { return XCTFail("应是时序图") }
        XCTAssertEqual(sequence.participants, ["手机", "Mac"])
        XCTAssertEqual(sequence.messages.count, 2)
        XCTAssertEqual(sequence.messages[0].from, "手机")
        XCTAssertEqual(sequence.messages[0].text, "打开文件")
        XCTAssertFalse(sequence.messages[0].isReturn)
        XCTAssertTrue(sequence.messages[1].isReturn, "虚线回包是返回")
    }

    func testUnsupportedDiagramIsNotGuessed() {
        XCTAssertNil(MermaidDocument.parse("gantt\n  title A"))
        XCTAssertNil(MermaidDocument.parse("pie\n  \"a\": 1"))
        XCTAssertNil(MermaidDocument.parse(""), "空文本不画")
        XCTAssertNil(MermaidDocument.parse("flowchart TD\n  style A fill:#f9f"), "只有样式行时不画空图")
    }
}
