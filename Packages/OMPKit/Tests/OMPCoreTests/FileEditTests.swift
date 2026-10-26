import XCTest
@testable import OMPCore

/// Editing a file then saving it must never silently drop the part that was
/// not loaded; the side panel and the phone's viewer share this rule.
final class FileEditTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompedit-\(UUID().uuidString).txt")
        try "original".write(to: url, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    func testWritesTheWholeText() throws {
        try FileEdit.write("changed", to: url, truncated: false)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "changed")
    }

    func testRefusesATruncatedFile() throws {
        XCTAssertThrowsError(try FileEdit.write("x", to: url, truncated: true)) { error in
            XCTAssertEqual(error as? FileEdit.Failure, .truncated)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original", "拒绝时不能改动原文件")
    }

    func testReportsAWriteFailure() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-nope-\(UUID().uuidString)/x.txt")
        XCTAssertThrowsError(try FileEdit.write("x", to: missing, truncated: false)) { error in
            guard case .writeFailed = error as? FileEdit.Failure else {
                return XCTFail("应是写入失败：\(error)")
            }
        }
    }
}
