import XCTest
@testable import OMPCore

/// The stdio transport sees arbitrary read boundaries. A framing slip drops,
/// merges or corrupts JSON-RPC messages and the client waits for a reply
/// that never comes.
final class MCPFramingTests: XCTestCase {
    private func feed(_ framer: inout MCPLineFramer, _ data: Data, chunk: Int) -> [MCPLineFramer.Output] {
        var outputs: [MCPLineFramer.Output] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = min(start + chunk, data.endIndex)
            // Slices keep their parent's indices, as reads handed down do.
            outputs += framer.push(data[start..<end])
            start = end
        }
        return outputs
    }

    func testMessageSplitAcrossManyChunksArrivesOnceAndWhole() {
        let message = #"{"jsonrpc":"2.0","id":7,"result":{"text":"你好，世界"}}"#
        var framer = MCPLineFramer()
        // 3-byte chunks also split the multi-byte characters.
        let outputs = feed(&framer, Data((message + "\n").utf8), chunk: 3)
        XCTAssertEqual(outputs, [.line(Data(message.utf8))])
        XCTAssertEqual(framer.finish(), [], "nothing is left over")
    }

    func testSeveralMessagesInOneChunkKeepTheirOrder() {
        var framer = MCPLineFramer()
        let outputs = framer.push(Data("{\"a\":1}\n{\"b\":2}\r\n\n   \n{\"c\":3}\n{\"d\"".utf8))
        XCTAssertEqual(outputs, [
            .line(Data(#"{"a":1}"#.utf8)), .line(Data(#"{"b":2}"#.utf8)), .line(Data(#"{"c":3}"#.utf8)),
        ], "CRLF is trimmed, blank lines are skipped, the unterminated tail waits")
        XCTAssertEqual(framer.push(Data(":4}\n".utf8)), [.line(Data(#"{"d":4}"#.utf8))])
    }

    func testOversizeLineIsDroppedAndTheNextMessageStillArrives() {
        var framer = MCPLineFramer(maxLineBytes: 16)
        let long = String(repeating: "x", count: 40)
        var outputs = feed(&framer, Data(long.utf8), chunk: 7)
        XCTAssertEqual(outputs, [], "nothing until the oversize line ends")
        outputs = framer.push(Data("yy\n{\"ok\":1}\n".utf8))
        XCTAssertEqual(outputs, [.oversize(42), .line(Data(#"{"ok":1}"#.utf8))])

        // Oversize within a single chunk, between two good lines.
        outputs = framer.push(Data("{\"a\":1}\n\(long)\n{\"b\":2}\n".utf8))
        XCTAssertEqual(outputs, [.line(Data(#"{"a":1}"#.utf8)), .oversize(40), .line(Data(#"{"b":2}"#.utf8))])
    }

    func testFinishDeliversAnUnterminatedLastMessage() {
        var framer = MCPLineFramer()
        XCTAssertEqual(framer.push(Data(#"{"last":true}"#.utf8)), [])
        XCTAssertEqual(framer.finish(), [.line(Data(#"{"last":true}"#.utf8))])
        XCTAssertEqual(framer.finish(), [])
    }

    func testLogRingKeepsTheLastLinesAndJoinsLinesSplitAcrossReads() {
        var ring = MCPLogRing(capacity: 3)
        ring.append(Data("one\ntw".utf8))
        ring.append(Data("o\r\nthree\nfour\nfi".utf8))
        XCTAssertEqual(ring.tail, ["three", "four", "fi"], "oldest dropped, the partial line shown last")
        ring.append(Data("ve\n".utf8))
        XCTAssertEqual(ring.tail, ["three", "four", "five"])

        var endless = MCPLogRing(capacity: 10)
        endless.append(Data(String(repeating: "z", count: MCPLogRing.maxLineBytes * 2 + 5).utf8))
        XCTAssertEqual(endless.tail.map(\.count), [MCPLogRing.maxLineBytes, MCPLogRing.maxLineBytes, 5])
    }

    func testDecodingClassifiesMessagesAndRepliesEchoTheIDForm() throws {
        let messages = MCPMessage.decodeAll(Data(#"""
        [{"jsonrpc":"2.0","id":"srv-1","method":"ping"},
         {"jsonrpc":"2.0","method":"notifications/tools/list_changed"},
         {"jsonrpc":"2.0","id":3,"result":{}},
         {"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"bad"}},
         {"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse"}},
         "not a message"]
        """#.utf8))
        XCTAssertEqual(messages, [
            .request(id: .string("srv-1"), method: "ping", params: nil),
            .notification(method: "notifications/tools/list_changed", params: nil),
            .response(id: .int(3), result: .object([:])),
            .error(id: .int(4), code: -32602, message: "bad"),
            .error(id: nil, code: -32700, message: "parse"),
        ])

        let reply = MCPMessage.response(id: .string("srv-1"), result: .object([:])).encoded()
        let decoded = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        XCTAssertEqual(decoded?["id"] as? String, "srv-1", "a string id is answered as a string")
        let numeric = MCPMessage.request(id: .int(12), method: "tools/list", params: nil).encoded()
        XCTAssertTrue(String(decoding: numeric, as: UTF8.self).contains(#""id":12,"#), "integer ids stay integers")
        let text = MCPMessage.notification(method: "x", params: .object(["s": .string("a\nb")])).encoded()
        XCTAssertFalse(text.contains(0x0A), "an encoded message never contains a raw newline")
    }
}
