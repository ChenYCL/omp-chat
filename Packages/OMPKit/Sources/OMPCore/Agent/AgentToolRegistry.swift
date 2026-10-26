import Foundation

/// The tools on offer for one model turn, merged from every provider, and
/// the way back from a wire name to the provider that serves it.
public struct AgentToolRegistry: Sendable {
    /// Two providers (or one provider twice) offered the same wire name. The
    /// first in provider-id order wins; the other is not offered.
    public struct Clash: Hashable, Sendable {
        public var name: String
        public var keptProviderID: String
        public var droppedProviderID: String
    }

    /// A spec dropped because its name breaks `^[a-zA-Z0-9_-]{1,64}$`, which
    /// gateways enforce by rejecting the whole request.
    public struct InvalidName: Hashable, Sendable {
        public var name: String
        public var providerID: String
    }

    private struct Entry: Sendable {
        var providerID: String
        var provider: any AgentToolProvider
        var spec: AgentToolSpec
    }

    private var entries: [Entry]
    public private(set) var clashes: [Clash]
    public private(set) var invalidNames: [InvalidName]

    public static let empty = AgentToolRegistry(entries: [], clashes: [], invalidNames: [])

    private init(entries: [Entry], clashes: [Clash], invalidNames: [InvalidName]) {
        self.entries = entries
        self.clashes = clashes
        self.invalidNames = invalidNames
    }

    /// Asks every provider for its tools. Order is stable: provider id, then
    /// tool name.
    public static func build(_ providers: [String: any AgentToolProvider]) async -> AgentToolRegistry {
        var entries: [Entry] = []
        var clashes: [Clash] = []
        var invalid: [InvalidName] = []
        var owner: [String: String] = [:]
        for providerID in providers.keys.sorted() {
            guard let provider = providers[providerID] else { continue }
            let specs = await provider.tools().sorted { $0.name < $1.name }
            for spec in specs {
                guard isValidName(spec.name) else {
                    invalid.append(InvalidName(name: spec.name, providerID: providerID))
                    continue
                }
                if let kept = owner[spec.name] {
                    clashes.append(Clash(name: spec.name, keptProviderID: kept, droppedProviderID: providerID))
                    continue
                }
                owner[spec.name] = providerID
                entries.append(Entry(providerID: providerID, provider: provider, spec: spec))
            }
        }
        return AgentToolRegistry(entries: entries, clashes: clashes, invalidNames: invalid)
    }

    /// Every offered tool, in the stable order above.
    public func specs() -> [AgentToolSpec] {
        entries.map(\.spec)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The provider serving the wire name `name`, if any.
    public func route(_ name: String) -> (providerID: String, provider: any AgentToolProvider, spec: AgentToolSpec)? {
        guard let entry = entries.first(where: { $0.spec.name == name }) else { return nil }
        return (entry.providerID, entry.provider, entry.spec)
    }

    /// The OpenAI function-name rule: 1–64 ASCII letters, digits, `_` or `-`.
    public static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count) else { return false }
        return name.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x5F || byte == 0x2D
        }
    }
}
