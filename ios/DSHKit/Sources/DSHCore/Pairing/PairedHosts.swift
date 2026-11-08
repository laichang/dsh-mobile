import Foundation
import Synchronization

/// A host this phone has paired with. Nothing here is secret: the host key is public and the
/// phone's own key is in the Keychain (`DeviceKeyStore`).
public struct PairedHost: Sendable, Equatable, Codable, Identifiable {
    /// Hex of the first 8 bytes of the host key; stable across address changes.
    public var id: String
    public var name: String
    /// The address that worked last first (pairing, then each reconnect, D98), then the others from the QR.
    public var addresses: [HostEndpoint]
    public var hostKey: [UInt8]
    public var pairedAt: Date

    public init(name: String, addresses: [HostEndpoint], hostKey: [UInt8], pairedAt: Date = .now) {
        self.id = hostKey.prefix(8).map { String(format: "%02x", $0) }.joined()
        self.name = name
        self.addresses = addresses
        self.hostKey = hostKey
        self.pairedAt = pairedAt
    }
}

/// The paired hosts, in pairing order.
public protocol PairedHostStore: Sendable {
    func load() -> [PairedHost]
    /// Adds the host, replacing any earlier pairing with the same host key.
    func save(_ host: PairedHost) throws
    /// Replaces the pairing with the same host key in its place (D98: a new address order).
    /// Does nothing if the host is not paired.
    func update(_ host: PairedHost) throws
    func removeAll() throws
}

/// A JSON file in Application Support.
public struct FilePairedHostStore: PairedHostStore {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? URL.applicationSupportDirectory.appending(path: "paired-hosts.json")
    }

    public func load() -> [PairedHost] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PairedHost].self, from: data)) ?? []
    }

    public func save(_ host: PairedHost) throws {
        try write(load().filter { $0.hostKey != host.hostKey } + [host])
    }

    public func update(_ host: PairedHost) throws {
        var hosts = load()
        guard let index = hosts.firstIndex(where: { $0.hostKey == host.hostKey }) else { return }
        hosts[index] = host
        try write(hosts)
    }

    private func write(_ hosts: [PairedHost]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(hosts).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

public final class InMemoryPairedHostStore: PairedHostStore {
    private let hosts: Mutex<[PairedHost]>

    public init(_ hosts: [PairedHost] = []) { self.hosts = Mutex(hosts) }

    public func load() -> [PairedHost] { hosts.withLock { $0 } }
    public func save(_ host: PairedHost) throws {
        hosts.withLock { $0 = $0.filter { $0.hostKey != host.hostKey } + [host] }
    }
    public func update(_ host: PairedHost) throws {
        hosts.withLock { hosts in
            if let index = hosts.firstIndex(where: { $0.hostKey == host.hostKey }) { hosts[index] = host }
        }
    }
    public func removeAll() throws { hosts.withLock { $0 = [] } }
}
