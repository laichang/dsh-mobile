import DSHTransport
import Foundation
import Synchronization

/// A host this phone has paired with. Nothing here is secret: the host key is public and the
/// phone's device credential is in the Keychain.
public struct PairedHost: Sendable, Equatable, Codable, Identifiable {
    /// Hex of the first 8 bytes of the host key; stable across address changes.
    public var id: String
    public var name: String
    /// The address that worked last first (pairing, then each reconnect), then the others from the QR.
    public var addresses: [HostEndpoint]
    public var hostKey: [UInt8]
    public var tlsDeviceID: String?
    var pendingCredentialID: String?
    public var cacheKey: String { "tls:" + id }
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
    /// Saves the new address order of an enrollment that is still paired.
    func update(_ host: PairedHost) throws
    func removeAll() throws
    func remove(id: String) throws
    /// Hides the pairing and returns the credentials awaiting deletion for this host.
    func retire(cacheKey: String) throws -> [PairedHost]
    /// Finishes persisted cleanup after credential deletion succeeds.
    func acknowledgeRemoval(of host: PairedHost) throws
}

extension PairedHostStore {
    public func retire(cacheKey: String) throws -> [PairedHost] {
        guard let host = load().first(where: { $0.cacheKey == cacheKey }) else { return [] }
        try remove(id: host.id)
        return [host]
    }

    public func acknowledgeRemoval(of host: PairedHost) throws {}
}

/// A JSON file in Application Support.
public struct FilePairedHostStore: PairedHostStore {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? URL.applicationSupportDirectory.appending(path: "paired-hosts.json")
    }

    // Store values can be created independently for the same file.
    private static let writers = Mutex(())

    private func read() throws -> [PairedHost] {
        do {
            return try JSONDecoder().decode([PairedHost].self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    public func load() -> [PairedHost] {
        (try? read().filter { $0.tlsDeviceID != nil }) ?? []
    }

    @discardableResult
    private func mutate<Result>(_ body: (inout [PairedHost]) -> Result) throws -> Result {
        try Self.writers.withLock { _ in
            let before = try read()
            var after = before
            let result = body(&after)
            if before != after {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(after).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            return result
        }
    }

    public func save(_ host: PairedHost) throws {
        try mutate {
            $0.removeAll { $0.hostKey == host.hostKey && $0.pendingCredentialID == nil }
            $0.append(host)
        }
    }

    public func update(_ host: PairedHost) throws {
        try mutate { hosts in
            guard let index = hosts.firstIndex(where: {
                $0.hostKey == host.hostKey && $0.tlsDeviceID == host.tlsDeviceID && $0.pendingCredentialID == nil
            }) else { return }
            hosts[index].addresses = host.addresses
        }
    }

    public func remove(id: String) throws {
        try mutate { $0.removeAll { $0.id == id && $0.pendingCredentialID == nil } }
    }

    public func removeAll() throws {
        try mutate { $0.removeAll { $0.pendingCredentialID == nil } }
    }

    public func retire(cacheKey: String) throws -> [PairedHost] {
        try mutate { hosts in
            var pending: [PairedHost] = []
            for index in hosts.indices where hosts[index].cacheKey == cacheKey {
                if let deviceID = hosts[index].tlsDeviceID {
                    hosts[index].pendingCredentialID = deviceID
                    hosts[index].tlsDeviceID = nil
                }
                if let deviceID = hosts[index].pendingCredentialID {
                    var host = hosts[index]
                    host.tlsDeviceID = deviceID
                    host.pendingCredentialID = nil
                    pending.append(host)
                }
            }
            return pending
        }
    }

    public func acknowledgeRemoval(of host: PairedHost) throws {
        guard let deviceID = host.tlsDeviceID else { return }
        try mutate { $0.removeAll { $0.hostKey == host.hostKey && $0.pendingCredentialID == deviceID } }
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
            if let index = hosts.firstIndex(where: { $0.hostKey == host.hostKey && $0.tlsDeviceID == host.tlsDeviceID }) {
                hosts[index].addresses = host.addresses
            }
        }
    }
    public func remove(id: String) throws { hosts.withLock { $0.removeAll { $0.id == id } } }
    public func removeAll() throws { hosts.withLock { $0 = [] } }
}
