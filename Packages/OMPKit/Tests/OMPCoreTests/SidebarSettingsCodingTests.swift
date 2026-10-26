import XCTest
@testable import OMPCore

/// New sidebar settings must decode from old documents; saved values round-trip.
final class SidebarSettingsCodingTests: XCTestCase {
    func testOldDocumentDecodesWithDefaults() throws {
        let json = #"{"version":1,"conversationSort":"updated"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.sidebarGrouping, "project")
        XCTAssertEqual(settings.sidebarFilter, "all")
    }

    func testStoredValuesRoundTrip() throws {
        var settings = AppSettings()
        settings.sidebarGrouping = "connection"
        settings.sidebarFilter = "work"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.sidebarGrouping, "connection")
        XCTAssertEqual(decoded.sidebarFilter, "work")
    }

    func testUnknownStoredValuesFallBack() throws {
        let json = #"{"sidebarGrouping":"nonsense","sidebarFilter":"42"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(SidebarGrouping(stored: settings.sidebarGrouping), .project)
        XCTAssertEqual(SidebarFilter(stored: settings.sidebarFilter), .all)
    }
}
