import XCTest
@testable import OMPCore

/// `ompchat://thread/<uuid>` is what 复制应用链接 puts on the clipboard and
/// what `.onOpenURL` reads back, so building and parsing must agree.
final class ThreadLinkTests: XCTestCase {
    func testRoundTrip() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let url = ThreadLink.url(for: id)
        XCTAssertEqual(url.absoluteString, "ompchat://thread/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(ThreadLink.threadID(in: url), id)
    }

    func testSchemeAndHostAreCaseInsensitive() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let url = URL(string: "OMPChat://THREAD/\(id.uuidString.lowercased())")!
        XCTAssertEqual(ThreadLink.threadID(in: url), id, "大小写不同也应解析")
    }

    func testOtherSchemesAreRejected() {
        XCTAssertNil(ThreadLink.threadID(in: URL(string: "https://thread/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!))
        XCTAssertNil(ThreadLink.threadID(in: URL(string: "ompchat://settings/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!))
    }

    func testMalformedUUIDsAreRejected() {
        XCTAssertNil(ThreadLink.threadID(in: URL(string: "ompchat://thread/not-a-uuid")!))
        XCTAssertNil(ThreadLink.threadID(in: URL(string: "ompchat://thread/")!))
        XCTAssertNil(ThreadLink.threadID(in: URL(string: "ompchat://thread")!))
    }
}
