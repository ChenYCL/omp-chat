import XCTest
import OMPCore

/// Wire rules for answering the Mac's approval cards from a phone: the
/// snapshot field, the argument cap, and the `approve` command, including
/// the LAN `/command` route.
final class RelayApprovalTests: XCTestCase {
    private func approval(arguments: String = #"{"command":"ls"}"#, canApprove: Bool = false) -> RelayApproval {
        RelayApproval(
            id: "A1", conversationID: "C1", callID: "call-1", toolName: "shell",
            source: "内置", risk: "execute", summary: "运行命令：ls",
            argumentsJSON: arguments, canApprove: canApprove
        )
    }

    private func object(_ snapshot: RelaySnapshot) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
    }

    // MARK: Snapshot

    func testSnapshotFromAnOldHostDecodesWithoutApprovals() throws {
        let json = #"{"rev":3,"host":"MacBook","selectedID":null,"conversations":[]}"#
        let snapshot = try JSONDecoder().decode(RelaySnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.rev, 3)
        XCTAssertNil(snapshot.approvals)
        XCTAssertNil(snapshot.commandFailures)
    }

    func testEmptyApprovalsAndFailuresAreLeftOffTheWire() throws {
        let snapshot = RelaySnapshot(rev: 1, host: "H", selectedID: nil, conversations: [], approvals: [], commandFailures: [])
        let keys = try object(snapshot).keys
        XCTAssertFalse(keys.contains("approvals"), "空列表不上线，旧手机看到的快照和以前一样")
        XCTAssertFalse(keys.contains("commandFailures"))

        let decoded = try JSONDecoder().decode(
            RelaySnapshot.self, from: Data(#"{"rev":1,"host":"H","conversations":[],"approvals":[],"commandFailures":[]}"#.utf8)
        )
        XCTAssertNil(decoded.approvals)
        XCTAssertNil(decoded.commandFailures)
    }

    func testSnapshotCarriesApprovalsAndFailuresBothWays() throws {
        let snapshot = RelaySnapshot(
            rev: 4, host: "H", selectedID: "C1", conversations: [],
            approvals: [approval()],
            commandFailures: [RelayCommandFailure(requestID: "r1", error: "shell_disabled")]
        )
        let wire = try object(snapshot)
        let card = try XCTUnwrap((wire["approvals"] as? [[String: Any]])?.first)
        XCTAssertEqual(card["risk"] as? String, "execute")
        XCTAssertEqual(card["canApprove"] as? Bool, false)
        XCTAssertEqual(card["callID"] as? String, "call-1")
        XCTAssertEqual((wire["commandFailures"] as? [[String: Any]])?.first?["requestID"] as? String, "r1")

        let decoded = try JSONDecoder().decode(RelaySnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }

    func testAnOddCardDoesNotBreakTheSnapshotAndCannotBeAllowed() throws {
        let json = #"{"rev":2,"host":"H","conversations":[],"approvals":[{"id":"A9","summary":"读文件"}]}"#
        let snapshot = try JSONDecoder().decode(RelaySnapshot.self, from: Data(json.utf8))
        let card = try XCTUnwrap(snapshot.approvals?.first)
        XCTAssertEqual(card.id, "A9")
        XCTAssertFalse(card.canApprove, "缺字段时按不能批准处理")
        XCTAssertEqual(card.risk, "execute")
    }

    // MARK: Argument cap

    func testLongArgumentsAreCutOnACharacterBoundaryWithAMarker() throws {
        let marker = RelayApproval.truncationMarker
        for unit in ["中", "😀", "a中😀"] {
            let long = String(repeating: unit, count: 3000)
            let capped = approval(arguments: long).argumentsJSON
            XCTAssertLessThanOrEqual(capped.utf8.count, RelayApproval.maxArgumentsBytes, unit)
            XCTAssertTrue(capped.hasSuffix(marker), unit)
            let body = String(capped.dropLast(marker.count))
            XCTAssertTrue(long.hasPrefix(body), "截断只在字符边界：\(unit)")
            XCTAssertFalse(body.contains("\u{FFFD}"), unit)
            XCTAssertGreaterThan(body.utf8.count, RelayApproval.maxArgumentsBytes - marker.utf8.count - 8, unit)
        }
    }

    func testArgumentsAtTheCapAreKeptWhole() {
        let exact = String(repeating: "a", count: RelayApproval.maxArgumentsBytes)
        XCTAssertEqual(approval(arguments: exact).argumentsJSON, exact)
    }

    func testDecodedArgumentsAreCappedToo() throws {
        let long = String(repeating: "中", count: 3000)
        let json = try JSONSerialization.data(withJSONObject: ["rev": 1, "host": "H", "conversations": [], "approvals": [["id": "A1", "argumentsJSON": long]]])
        let card = try XCTUnwrap(JSONDecoder().decode(RelaySnapshot.self, from: json).approvals?.first)
        XCTAssertLessThanOrEqual(card.argumentsJSON.utf8.count, RelayApproval.maxArgumentsBytes)
        XCTAssertTrue(card.argumentsJSON.hasSuffix(RelayApproval.truncationMarker))
    }

    // MARK: Policy

    func testPhoneMayAllowAReadAlwaysAndAnythingElseOnlyWithShellAccess() {
        for risk in ToolRisk.allCases {
            XCTAssertTrue(RelayApproval.phoneMayAllow(risk, allowShell: true), risk.rawValue)
            XCTAssertEqual(RelayApproval.phoneMayAllow(risk, allowShell: false), risk == .read, risk.rawValue)
        }
    }

    // MARK: approve command

    func testApproveRoundTripsThroughTheWire() throws {
        for command in [
            RelayCommand.approve(approvalID: "A1", decision: .allowOnce, requestID: "r1"),
            RelayCommand.approve(approvalID: "A1", decision: .deny, requestID: nil),
        ] {
            let data = try JSONEncoder().encode(RelayCommandWire(command))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["kind"] as? String, "approve")
            XCTAssertEqual(object["approvalID"] as? String, "A1")
            XCTAssertEqual(try JSONDecoder().decode(RelayCommandWire.self, from: data).command, command)
        }
        let allow = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            RelayCommandWire(.approve(approvalID: "A1", decision: .allowOnce, requestID: "r1"))
        )) as? [String: Any]
        XCTAssertEqual(allow?["decision"] as? String, "allowOnce")
        XCTAssertEqual(allow?["requestID"] as? String, "r1")
    }

    func testMalformedApproveIsNotACommand() throws {
        let bodies = [
            #"{"kind":"approve","decision":"deny"}"#,
            #"{"kind":"approve","approvalID":"","decision":"deny"}"#,
            #"{"kind":"approve","approvalID":"A1"}"#,
            #"{"kind":"approve","approvalID":"A1","decision":"maybe"}"#,
            #"{"kind":"approve","approvalID":"A1","decision":"allowAlways"}"#,
        ]
        for body in bodies {
            let wire = try JSONDecoder().decode(RelayCommandWire.self, from: Data(body.utf8))
            XCTAssertNil(wire.command, body)
        }
    }

    // MARK: LAN route

    func testCommandRouteDeliversApproveAndRefusesAllowAlways() async throws {
        let server = RelayServer()
        let token = UUID().uuidString
        try server.start(port: 0, token: token)
        defer { server.stop() }
        let received = Received()
        let delivered = expectation(description: "approve delivered")
        server.onInput = { command in
            await received.append(command)
            delivered.fulfill()
        }

        func post(_ body: String) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/command")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue(token, forHTTPHeaderField: "X-OMP-Token")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }

        let refused = try await post(#"{"kind":"approve","approvalID":"A1","decision":"allowAlways","requestID":"r0"}"#)
        XCTAssertEqual(refused, 400, "手机不能给出始终允许")
        let accepted = try await post(#"{"kind":"approve","approvalID":"A1","decision":"allowOnce","requestID":"r1"}"#)
        XCTAssertEqual(accepted, 200)
        await fulfillment(of: [delivered], timeout: 5)
        let commands = await received.commands
        XCTAssertEqual(commands, [.approve(approvalID: "A1", decision: .allowOnce, requestID: "r1")])
    }
}

private actor Received {
    var commands: [RelayCommand] = []
    func append(_ command: RelayCommand) { commands.append(command) }
}
