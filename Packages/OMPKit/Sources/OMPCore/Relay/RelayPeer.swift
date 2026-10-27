import Foundation
import Network

/// Who is on the other end of a relay connection.
enum RelayPeer {
    /// True when the connection comes from this Mac itself: `127.0.0.0/8`,
    /// `::1`, or the IPv4-mapped form `::ffff:127.0.0.1` a dual-stack listener
    /// reports.
    ///
    /// The `/debug/*` routes are loopback-only because the pairing token is the
    /// same one a phone holds. Those routes can send messages, answer approval
    /// cards, install MCP servers and run git; letting a paired phone reach them
    /// would bypass 「允许手机访问文件与终端」, which is what keeps the phone out
    /// of the Mac's files and shell by default.
    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return isLoopback(address)
        case .ipv6(let address):
            if address.isLoopback { return true }
            return address.asIPv4.map(isLoopback) ?? false
        case .name:
            // An inbound connection reports an address, never a name; do not
            // trust one if it ever does.
            return false
        @unknown default:
            return false
        }
    }

    /// `IPv4Address.isLoopback` is true for 127.0.0.1 only; the OS treats all
    /// of 127/8 as local, and a remote host cannot send from it.
    private static func isLoopback(_ address: IPv4Address) -> Bool {
        address.rawValue.first == 127
    }
}
