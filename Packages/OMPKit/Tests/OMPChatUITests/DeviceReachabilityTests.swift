import XCTest
import OMPCore
@testable import OMPChatUI

final class DeviceReachabilityTests: XCTestCase {
    private struct Boom: LocalizedError { var errorDescription: String? { "Token 不匹配（401）" } }

    private func device(_ name: String) -> PairedDevice {
        PairedDevice(name: name, transport: .lan, host: name, port: 1, token: "t")
    }

    private actor Collector {
        var results: [UUID: DeviceReachability] = [:]
        func set(_ id: UUID, _ value: DeviceReachability) { results[id] = value }
    }

    func testEachDeviceGetsItsOwnResult() async {
        let ok = device("ok"), bad = device("bad")
        let collector = Collector()
        await DeviceReachability.check([ok, bad], probe: { d in if d.host == "bad" { throw Boom() } }) {
            await collector.set($0, $1)
        }
        let results = await collector.results
        XCTAssertEqual(results[ok.id], .online)
        XCTAssertEqual(results[bad.id], .offline("Token 不匹配（401）"), "失败原因应原样保留")
    }

    func testSlowDeviceTimesOutWithoutBlockingTheFastOne() async {
        let fast = device("fast"), slow = device("slow")
        let collector = Collector()
        let started = Date()
        await DeviceReachability.check([fast, slow], timeout: .milliseconds(200), probe: { d in
            if d.host == "slow" { try await Task.sleep(for: .seconds(30)) }
        }) { await collector.set($0, $1) }
        let results = await collector.results
        XCTAssertEqual(results[fast.id], .online)
        XCTAssertEqual(results[slow.id], .offline("超时"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "慢设备不应拖到它自己的 30 秒")
    }

    func testNoDevicesIsANoOp() async {
        await DeviceReachability.check([], probe: { _ in XCTFail("不应探测") }) { _, _ in XCTFail("不应有结果") }
    }
}
