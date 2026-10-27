import Network
import XCTest
@testable import OMPCore

/// `/debug/*` can send messages, answer approvals and install servers with the
/// same token a paired phone holds; only the loopback peer rule keeps a phone
/// from using it to get around 「允许手机访问文件与终端」.
final class RelayPeerTests: XCTestCase {
    private func endpoint(_ host: String) throws -> NWEndpoint {
        let address = try XCTUnwrap(IPv4Address(host) ?? nil, host)
        return .hostPort(host: .ipv4(address), port: 8795)
    }

    private func endpoint6(_ host: String) throws -> NWEndpoint {
        let address = try XCTUnwrap(IPv6Address(host) ?? nil, host)
        return .hostPort(host: .ipv6(address), port: 8795)
    }

    func testLoopbackAddressesAreLocal() throws {
        XCTAssertTrue(RelayPeer.isLoopback(try endpoint("127.0.0.1")))
        XCTAssertTrue(RelayPeer.isLoopback(try endpoint("127.5.6.7")), "the whole 127/8 block is loopback")
        XCTAssertTrue(RelayPeer.isLoopback(try endpoint6("::1")))
        XCTAssertTrue(RelayPeer.isLoopback(try endpoint6("::ffff:127.0.0.1")), "a dual-stack listener reports this form")
    }

    func testLanAndPublicAddressesAreNotLocal() throws {
        XCTAssertFalse(RelayPeer.isLoopback(try endpoint("192.168.1.20")), "a phone on the same Wi-Fi")
        XCTAssertFalse(RelayPeer.isLoopback(try endpoint("10.0.0.2")))
        XCTAssertFalse(RelayPeer.isLoopback(try endpoint("0.0.0.0")))
        XCTAssertFalse(RelayPeer.isLoopback(try endpoint6("fe80::1")))
        XCTAssertFalse(RelayPeer.isLoopback(try endpoint6("::ffff:192.168.1.20")), "mapped LAN address is still LAN")
    }

    func testNamesAndOtherEndpointsAreNeverTrusted() {
        XCTAssertFalse(RelayPeer.isLoopback(.hostPort(host: .name("localhost", nil), port: 8795)),
                       "a name is not proof of where the connection came from")
        XCTAssertFalse(RelayPeer.isLoopback(.unix(path: "/tmp/x")))
    }
}
