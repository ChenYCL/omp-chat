import Foundation
import Network

/// Registers the relay HTTP service on the local network via Bonjour so iOS
/// devices can discover the host.
///
/// On macOS, `NWListener` refuses a second listener bound to a port already
/// owned by another listener (even with `allowLocalEndpointReuse`), so the
/// advertiser does not create its own listener. Instead it attaches the
/// Bonjour service to the already-bound listener owned by [`RelayServer`];
/// `start(name:port:)` throws `RelayAdvertiserError.portMismatch` when
/// `port` does not match the relay's currently bound port.
public final class RelayAdvertiser {
    private let queue = DispatchQueue(label: "com.ompchat.relay.advertiser")
    private weak var server: RelayServer?
    private var listener: NWListener?
    private var ownListener = false

    /// Creates an advertiser attached to the `RelayServer`'s listener
    /// (preferred; see the class documentation). The listener is resolved
    /// lazily in `start(name:port:)`, so this may be created before the
    /// server starts.
    public init(attachedTo server: RelayServer) {
        self.server = server
        ownListener = false
    }

    /// Creates a standalone advertiser owning its own listener. Only valid
    /// when `port` is not already bound by another `NWListener`.
    public init(port: UInt16) {
        let parameters = NWParameters.tcp
        listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        ownListener = true
    }

    deinit {
        if ownListener { listener?.cancel() }
    }

    /// Registers `_ompchat._tcp.` with TXT record `ver=1` under `name` on
    /// `port`.
    public func start(name: String, port: UInt16) throws {
        let box = FailureBox()
        let ready = DispatchSemaphore(value: 0)
        let setup: () throws -> Void = { [weak self] in
            guard let self else { throw RelayAdvertiserError.notAttached }
            if !self.ownListener {
                self.listener = self.server?.bonjourListener()
            }
            guard let listener = self.listener else {
                throw RelayAdvertiserError.notAttached
            }
            guard let bound = listener.port?.rawValue, bound > 0 else {
                throw RelayAdvertiserError.portMismatch
            }
            guard bound == port else { throw RelayAdvertiserError.portMismatch }
            let service = NWListener.Service(
                name: name,
                type: "_ompchat._tcp.",
                domain: nil,
                txtRecord: NWTXTRecord(["ver": "1"])
            )
            listener.service = service
            listener.serviceRegistrationUpdateHandler = { change in
                switch change {
                case .add:
                    box.failure = FailureBox.Container.none
                    ready.signal()
                case .remove:
                    break
                }
            }
            if self.ownListener {
                listener.newConnectionHandler = { _ in }
                listener.start(queue: self.queue)
            }
        }
        do {
            try queue.sync { try setup() }
        } catch {
            throw error
        }
        ready.wait()
        if case .some(let failure) = box.failure {
            queue.sync {
                listener?.serviceRegistrationUpdateHandler = nil
                listener?.service = nil
            }
            throw failure
        }
    }

    /// Unregisters the Bonjour service. Does not stop the relay listener.
    public func stop() {
        queue.sync {
            listener?.serviceRegistrationUpdateHandler = nil
            listener?.service = nil
        }
    }
}

/// Errors thrown by [`RelayAdvertiser`].
public enum RelayAdvertiserError: Error, Sendable {
    /// No listener available to attach the service to.
    case notAttached
    /// Requested port differs from the relay listener's bound port.
    case portMismatch
}

/// Thread-safe box for the service-registration failure, signalled through a
/// semaphore whose waiter runs on a different thread than the advertiser
/// queue.
private final class FailureBox: @unchecked Sendable {
    enum Container {
        case none
        case some(any Error)
    }

    var failure: Container = .none
}
