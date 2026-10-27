import Foundation
import XCTest
@testable import OMPCore

/// The four main-actor automation routes must answer `main_thread_busy` when
/// the main actor is blocked, and keep working normally when it is free.
final class RelayServerMainThreadBusyTests: XCTestCase {
    private var server: RelayServer!
    private var token: String!
    private var baseURL: URL!

    override func setUp() {
        super.setUp()
        server = RelayServer()
        token = UUID().uuidString
        server.mainActorStartTimeout = 0.2
        try? server.start(port: 0, token: token)
        baseURL = URL(string: "http://127.0.0.1:\(server.port)")
    }

    override func tearDown() {
        server.stop()
        server = nil
        token = nil
        baseURL = nil
        super.tearDown()
    }

    private func get(_ path: String, timeout: TimeInterval = 10) async -> (Int, String) {
        await withCheckedContinuation { continuation in
            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.timeoutInterval = timeout
            request.setValue(token, forHTTPHeaderField: "X-OMP-Token")
            URLSession.shared.dataTask(with: request) { data, response, _ in
                continuation.resume(returning: (
                    (response as? HTTPURLResponse)?.statusCode ?? 0,
                    String(decoding: data ?? Data(), as: UTF8.self)
                ))
            }.resume()
        }
    }

    func testAFreeMainActorAnswersNormally() async {
        server.onDebugState = { Data(#"{"ok":true}"#.utf8) }
        let (status, body) = await get("/debug/state")
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("ok"))
    }

    func testABlockedMainActorAnswersBusyQuickly() async {
        let release = DispatchSemaphore(value: 0)
        let blocker = Task { @MainActor in
            release.wait()
        }
        // Let the blocker take the main actor first.
        try? await Task.sleep(nanoseconds: 150_000_000)
        server.onDebugState = { Data("{}".utf8) }
        server.onDebugAction = { _ in .success }

        let start = Date()
        let (stateStatus, stateBody) = await get("/debug/state", timeout: 5)
        XCTAssertEqual(stateStatus, 503)
        XCTAssertTrue(stateBody.contains("main_thread_busy"), stateBody)

        let (windowsStatus, _) = await get("/debug/windows", timeout: 5)
        XCTAssertEqual(windowsStatus, 503)

        var pair = URLRequest(url: baseURL.appendingPathComponent("/pair"))
        pair.timeoutInterval = 5
        let (pairStatus, _) = await withCheckedContinuation { (continuation: CheckedContinuation<(Int, String), Never>) in
            URLSession.shared.dataTask(with: pair) { data, response, _ in
                continuation.resume(returning: (
                    (response as? HTTPURLResponse)?.statusCode ?? 0,
                    String(decoding: data ?? Data(), as: UTF8.self)
                ))
            }.resume()
        }
        XCTAssertEqual(pairStatus, 401)

        XCTAssertLessThan(Date().timeIntervalSince(start), 4, "超时要快，不能等主线程空出来")
        release.signal()
        _ = await blocker.result

        // Free again: the same hooks work.
        let (recovered, _) = await get("/debug/state", timeout: 5)
        XCTAssertEqual(recovered, 200)
    }

    func testAnAbandonedActionNeverRunsLate() async {
        let release = DispatchSemaphore(value: 0)
        let blocker = Task { @MainActor in
            release.wait()
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let counter = ManagedAtomic(0)
        server.onDebugAction = { _ in
            counter.wrappingIncrement(by: 1)
            return .success
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("/debug/action"))
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-OMP-Token")
        request.httpBody = Data(#"{"action":"stop"}"#.utf8)
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<(Int, String), Never>) in
            URLSession.shared.dataTask(with: request) { data, response, _ in
                continuation.resume(returning: (
                    (response as? HTTPURLResponse)?.statusCode ?? 0,
                    String(decoding: data ?? Data(), as: UTF8.self)
                ))
            }.resume()
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(counter.value, 0, "主线程空出来后不能把放弃的动作再跑一遍")
        release.signal()
        _ = await blocker.result
    }
}

/// swift-atomics is not a dependency; a lock is enough for one counter.
private final class ManagedAtomic: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0
    init(_ value: Int) { self.value = value }
    func wrappingIncrement(by amount: Int) { lock.lock(); value += amount; lock.unlock() }
    
}
