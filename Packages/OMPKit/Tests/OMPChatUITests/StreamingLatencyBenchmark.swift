import XCTest
import OMPCore
@testable import OMPChatUI

/// Benchmark for the phone terminal's live-output gap, driven by `autoresearch.sh`.
///
/// Measures how long a remote caller waits before seeing the first byte of a
/// command that prints immediately and then keeps running. Without streaming the
/// first byte only arrives with the final `exec` answer (≈ the command's full
/// runtime); with `background` + `exec.poll` it arrives on the first poll.
///
/// Requests go through the JSON wire form on purpose, so this file compiles and
/// runs against hosts with or without the streaming fields: an `exec.poll` the
/// host does not know falls back to the blocking `exec` path.
///
/// Skipped unless `OMP_BENCH=1`, so it never slows the regular suite.
final class StreamingLatencyBenchmark: XCTestCase {
    private static let command = "printf first; sleep 2; printf last"
    private static let pollInterval: UInt64 = 100_000_000

    func testFirstOutputLatency() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OMP_BENCH"] == "1", "set OMP_BENCH=1")
        let home = FileManager.default.temporaryDirectory.path
        let executor = HostExecutor(shellAllowed: true, homeDirectory: home)

        var firstSamples: [Double] = []
        var totalSamples: [Double] = []
        var streamed = 0
        for run in 0..<3 {
            let sample = try await measure(executor, id: "bench-\(run)")
            firstSamples.append(sample.first)
            totalSamples.append(sample.total)
            if sample.streamed { streamed += 1 }
        }

        print("METRIC first_output_ms=\(Int(median(firstSamples)))")
        print("METRIC total_ms=\(Int(median(totalSamples)))")
        print("METRIC streamed_runs=\(streamed)")
    }

    private struct Sample { var first: Double; var total: Double; var streamed: Bool }

    private func measure(_ executor: HostExecutor, id: String) async throws -> Sample {
        let start = Date()
        let started = try await call(executor, ["id": id, "op": "exec", "command": Self.command, "background": true])

        // Old hosts ignore `background` and answer with the finished command.
        if started["text"] as? String != "started" {
            let output = (started["stdout"] as? String) ?? ""
            XCTAssertTrue(output.contains("first"), "blocking exec must still return output: \(started)")
            let elapsed = Date().timeIntervalSince(start) * 1000
            return Sample(first: elapsed, total: elapsed, streamed: false)
        }

        var offset = 0
        var firstAt: Double?
        while true {
            let poll = try await call(executor, ["id": "\(id)-p\(offset)", "op": "exec.poll", "requestID": id, "offset": offset])
            XCTAssertEqual(poll["ok"] as? Bool, true, "poll failed: \(poll)")
            if let text = poll["text"] as? String, !text.isEmpty, firstAt == nil {
                firstAt = Date().timeIntervalSince(start) * 1000
            }
            offset = (poll["nextOffset"] as? Int) ?? offset
            if poll["done"] as? Bool == true { break }
            if Date().timeIntervalSince(start) > 30 { XCTFail("stream never finished"); break }
            try await Task.sleep(nanoseconds: Self.pollInterval)
        }
        let total = Date().timeIntervalSince(start) * 1000
        return Sample(first: firstAt ?? total, total: total, streamed: true)
    }

    private func call(_ executor: HostExecutor, _ body: [String: Any]) async throws -> [String: Any] {
        let request = try JSONDecoder().decode(HostRPCRequest.self, from: JSONSerialization.data(withJSONObject: body))
        let response = await executor.handle(request)
        let data = try JSONEncoder().encode(response)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
