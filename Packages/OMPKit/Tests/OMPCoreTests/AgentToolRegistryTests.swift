import XCTest
@testable import OMPCore

/// A provider with fixed tools that echoes its arguments.
private struct StaticProvider: AgentToolProvider {
    var names: [String]
    var source: String

    func tools() async -> [AgentToolSpec] {
        names.map { AgentToolSpec(name: $0, description: "", parametersJSON: "{}", risk: .read, source: source) }
    }

    func call(_ name: String, argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolOutput {
        AgentToolOutput(text: "\(source):\(name)")
    }
}

final class AgentToolRegistryTests: XCTestCase {
    func testSpecsAreOrderedByProviderThenName() async {
        let registry = await AgentToolRegistry.build([
            "skills": StaticProvider(names: ["zeta", "alpha"], source: "skills"),
            "builtin": StaticProvider(names: ["shell", "read_file"], source: "builtin"),
            "mcp": StaticProvider(names: ["browser_click"], source: "mcp"),
        ])
        XCTAssertEqual(registry.specs().map(\.name), ["read_file", "shell", "browser_click", "alpha", "zeta"])
        XCTAssertTrue(registry.clashes.isEmpty)
        XCTAssertTrue(registry.invalidNames.isEmpty)
    }

    func testDuplicateNameKeepsFirstProviderAndRecordsClash() async throws {
        let registry = await AgentToolRegistry.build([
            "mcp": StaticProvider(names: ["read_file", "fetch"], source: "mcp"),
            "builtin": StaticProvider(names: ["read_file"], source: "builtin"),
        ])
        XCTAssertEqual(registry.specs().map(\.name), ["read_file", "fetch"])
        XCTAssertEqual(registry.clashes, [.init(name: "read_file", keptProviderID: "builtin", droppedProviderID: "mcp")])
        let route = try XCTUnwrap(registry.route("read_file"))
        XCTAssertEqual(route.providerID, "builtin")
        let output = try await route.provider.call("read_file", argumentsJSON: "{}", context: .init(conversationID: UUID(), workingDirectory: nil))
        XCTAssertEqual(output.text, "builtin:read_file")
        XCTAssertEqual(registry.route("fetch")?.providerID, "mcp")
    }

    func testDuplicateWithinOneProviderIsAClashToo() async {
        let registry = await AgentToolRegistry.build(["mcp": StaticProvider(names: ["go", "go"], source: "mcp")])
        XCTAssertEqual(registry.specs().map(\.name), ["go"])
        XCTAssertEqual(registry.clashes.count, 1)
    }

    func testInvalidNamesAreDroppedAndReported() async {
        let long = String(repeating: "a", count: 65)
        let maxLength = String(repeating: "b", count: 64)
        let registry = await AgentToolRegistry.build([
            "mcp": StaticProvider(names: ["ok-name_1", "has space", "", long, maxLength, "点击", "a.b", "x/y"], source: "mcp"),
        ])
        XCTAssertEqual(registry.specs().map(\.name), [maxLength, "ok-name_1"])
        XCTAssertEqual(Set(registry.invalidNames.map(\.name)), ["has space", "", long, "点击", "a.b", "x/y"])
        XCTAssertNil(registry.route("has space"))
        XCTAssertTrue(registry.invalidNames.allSatisfy { $0.providerID == "mcp" })
    }

    func testUnknownNameDoesNotRoute() async {
        let registry = await AgentToolRegistry.build(["builtin": StaticProvider(names: ["shell"], source: "builtin")])
        XCTAssertNil(registry.route("Shell"))
        XCTAssertNil(registry.route(""))
        XCTAssertTrue(AgentToolRegistry.empty.isEmpty)
    }
}
