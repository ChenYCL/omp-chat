import Foundation
import XCTest
@testable import OMPCore

final class DiagnosticsTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DiagnosticsCenter.shared.resetBuffer()
        DiagnosticsCenter.shared.setLogDirectory(directory)
        DiagnosticsCenter.shared.setDiskEnabled(true)
    }

    override func tearDown() {
        DiagnosticsCenter.shared.setDiskEnabled(false)
        DiagnosticsCenter.shared.setLogDirectory(nil)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func testRingBufferCapsAtFiveHundredAndKeepsOrder() {
        for index in 1...600 {
            DiagnosticsCenter.shared.record("test", .info, "event \(index)")
        }
        let events = DiagnosticsCenter.shared.events(since: 0)
        XCTAssertEqual(events.count, DiagnosticsCenter.capacity)
        XCTAssertEqual(events.first?.seq, 101)
        XCTAssertEqual(events.last?.seq, 600)
        XCTAssertEqual(events.map(\.seq), events.map(\.seq).sorted())
        XCTAssertEqual(events.first?.message, "event 101")
        XCTAssertEqual(events.last?.message, "event 600")
    }

    func testSinceFiltersBySequence() {
        for index in 1...5 {
            DiagnosticsCenter.shared.record("test", .info, "event \(index)")
        }
        let events = DiagnosticsCenter.shared.events(since: 3)
        XCTAssertEqual(events.map(\.seq), [4, 5])
        XCTAssertTrue(DiagnosticsCenter.shared.events(since: 5).isEmpty)
    }

    func testMaskingHidesCredentials() {
        let samples = [
            "Authorization: Bearer sk-supersecretvalue1234",
            "token=abcdef0123456789",
            "api_key: sk-anothersecretkey999",
            "password=hunter2hunter2",
            "room=AB12CD",
        ]
        for sample in samples {
            let masked = DiagnosticsMask.mask(sample)
            XCTAssertFalse(masked.contains("supersecret"), sample)
            XCTAssertFalse(masked.contains("abcdef0123456789"), sample)
            XCTAssertFalse(masked.contains("anothersecretkey"), sample)
            XCTAssertFalse(masked.contains("hunter2"), sample)
            XCTAssertFalse(masked.contains("AB12CD"), sample)
            XCTAssertTrue(masked.contains("***"), sample)
        }

        DiagnosticsCenter.shared.record(
            "test", .info, "using token=abcdef0123456789",
            fields: ["Authorization": "Bearer sk-supersecretvalue1234"])
        let event = DiagnosticsCenter.shared.events(since: 0).last
        XCTAssertFalse(event?.message.contains("abcdef0123456789") ?? true)
        XCTAssertEqual(event?.fields["Authorization"], "Bearer ***")
    }

    func testJSONLRotatesAtOneMegabyte() throws {
        let payload = String(repeating: "x", count: 4000)
        for _ in 0..<300 {
            DiagnosticsCenter.shared.record("test", .info, payload)
        }
        let current = directory.appendingPathComponent("events.jsonl")
        let previous = directory.appendingPathComponent("events.1.jsonl")
        XCTAssertLessThan(try fileSize(current), DiagnosticsCenter.rotateBytes)
        XCTAssertGreaterThan(try fileSize(previous), 0)

        let lines = try String(contentsOf: current, encoding: .utf8).split(separator: "\n")
        XCTAssertFalse(lines.isEmpty)
        let decoded = try decoder().decode(DiagnosticsEvent.self, from: Data(lines[0].utf8))
        XCTAssertEqual(decoded.category, "test")
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    func testReportEncodesMarkdownAndJSON() throws {
        let event = DiagnosticsEvent(
            seq: 7, timestamp: Date(timeIntervalSince1970: 0),
            category: "relay", level: .info, message: "listening", fields: [:])
        let check = DiagnosticsCheckResult(
            id: "store", title: "存储目录", status: .ok, detail: "可写")
        let report = DiagnosticsReport(
            appVersion: "0.1.0", platform: "macOS", osVersion: "15.0.0",
            timestamp: Date(timeIntervalSince1970: 0),
            checks: [check], events: [event])

        let markdown = report.markdown()
        XCTAssertTrue(markdown.contains("OMPChat 诊断报告"))
        XCTAssertTrue(markdown.contains("| ok | 存储目录 | 可写 |"))
        XCTAssertTrue(markdown.contains("relay: listening"))

        let data = try report.jsonData()
        let decoded = try decoder().decode(DiagnosticsReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }
}
