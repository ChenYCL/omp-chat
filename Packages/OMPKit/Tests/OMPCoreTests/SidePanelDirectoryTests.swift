import XCTest
@testable import OMPCore

/// The side panel follows the thread: a bound directory wins, an unbound
/// thread keeps whatever the panel already shows (including a folder the user
/// picked by hand).
final class SidePanelDirectoryTests: XCTestCase {
    func testThreadDirectoryWins() {
        XCTAssertEqual(
            SidePanelDirectory.resolve(threadDirectory: "/tmp/repo", current: "/"),
            "/tmp/repo"
        )
    }

    func testUnboundThreadKeepsCurrentDirectory() {
        XCTAssertEqual(
            SidePanelDirectory.resolve(threadDirectory: nil, current: "/Users/me/picked"),
            "/Users/me/picked"
        )
    }

    func testEmptyThreadDirectoryCountsAsUnbound() {
        // An empty string can only come from bad data; treating it as a
        // directory would break every listing.
        XCTAssertEqual(
            SidePanelDirectory.resolve(threadDirectory: "", current: "/"),
            "/"
        )
    }

    func testSwitchingBackToUnboundThreadKeepsLastDirectory() {
        // The rule is stateless per call: the view passes what it currently
        // shows, so returning from a bound thread to an unbound one simply
        // keeps the last value it was handed.
        var current = "/Users/me/picked"
        current = SidePanelDirectory.resolve(threadDirectory: "/tmp/repo", current: current)
        XCTAssertEqual(current, "/tmp/repo")
        current = SidePanelDirectory.resolve(threadDirectory: nil, current: current)
        XCTAssertEqual(current, "/tmp/repo")
    }
}
