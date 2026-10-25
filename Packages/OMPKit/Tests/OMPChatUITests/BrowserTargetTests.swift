import XCTest
@testable import OMPChatUI

/// The Browser tab turned every bare host into https, which broke local URLs —
/// including the relay's own http health endpoint.
final class BrowserTargetTests: XCTestCase {
    private func resolve(_ raw: String) -> String {
        BrowserTarget.resolve(raw, fallback: "https://example.com")
    }

    func testExplicitSchemeIsKept() {
        XCTAssertEqual(resolve("http://127.0.0.1:8795/v1/health"), "http://127.0.0.1:8795/v1/health")
        XCTAssertEqual(resolve("https://example.com"), "https://example.com")
    }

    func testLocalHostsGetHTTP() {
        XCTAssertEqual(resolve("127.0.0.1:8795"), "http://127.0.0.1:8795")
        XCTAssertEqual(resolve("localhost:3000/x"), "http://localhost:3000/x")
        XCTAssertEqual(resolve("localhost"), "http://localhost")
    }

    func testPublicBareHostGetsHTTPS() {
        XCTAssertEqual(resolve("example.com"), "https://example.com")
    }

    func testWordsBecomeASearch() {
        XCTAssertTrue(resolve("swift ui").hasPrefix("https://www.baidu.com/s?wd="), "带空格按搜索处理")
        XCTAssertTrue(resolve("mermaid").hasPrefix("https://www.baidu.com/s?wd="), "没有点的单词也是搜索")
    }

    func testEmptyKeepsWhatIsOpen() {
        XCTAssertEqual(resolve("   "), "https://example.com")
    }
}
