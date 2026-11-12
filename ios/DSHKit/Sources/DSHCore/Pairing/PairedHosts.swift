import DSHPlatform
import DSHTransport
import Foundation
import Synchronization

/// Identifies one registration, including after the same host pairs again.
public struct HostEnrollment: Hashable, Sendable {
    public let hostKey: [UInt8]
    public let tlsDeviceID: String
}

/// A host this phone has paired with. Nothing here is secret: the host key is public and the
/// phone's device credential is in the Keychain.
public struct PairedHost: Sendable, Equatable, Codable, Identifiable {
    /// Hex of the first 8 bytes of the host key; stable across address changes.
    public var id: String
    public var name: String
    /// The address that worked last first (pairing, then each reconnect), then the others from the QR.
    package var addresses: [HostEndpoint]
    public var addressDescriptions: [String] { addresses.map(\.description) }
    public var hostKey: [UInt8]
    public var tlsDeviceID: String?
    public var enrollment: HostEnrollment? {
        tlsDeviceID.map { HostEnrollment(hostKey: hostKey, tlsDeviceID: $0) }
    }
    var pendingCredentialID: String?
    public var cacheKey: String { "tls:" + id }
    public var pairedAt: Date

    package init(name: String, addresses: [HostEndpoint], hostKey: [UInt8], pairedAt: Date = .now) {
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
    /// Persist the cleanup intent. Returns true when this was the visible registration.
    func retire(_ enrollment: HostEnrollment) throws -> Bool
    func pendingRemovals() throws -> [HostEnrollment]
    func acknowledgeRemoval(of enrollment: HostEnrollment) throws
}

private extension Array where Element == PairedHost {
    mutating func save(_ host: PairedHost) {
        for index in indices where self[index].hostKey == host.hostKey && self[index].pendingCredentialID == nil {
            if let displaced = self[index].enrollment, displaced != host.enrollment {
                self[index].tlsDeviceID = nil
                self[index].pendingCredentialID = displaced.tlsDeviceID
            }
        }
        removeAll { $0.hostKey == host.hostKey && $0.pendingCredentialID == nil }
        append(host)
    }

    mutating func retire(_ enrollment: HostEnrollment) -> Bool {
        if let index = firstIndex(where: { $0.enrollment == enrollment }) {
            self[index].tlsDeviceID = nil
            self[index].pendingCredentialID = enrollment.tlsDeviceID
            return true
        }
        // A replacement may already have displaced this registration before its close arrives.
        if pendingRemovals.contains(enrollment) {
            return !contains { $0.hostKey == enrollment.hostKey && $0.tlsDeviceID != nil }
        }
        var pending = PairedHost(name: "", addresses: [], hostKey: enrollment.hostKey)
        pending.pendingCredentialID = enrollment.tlsDeviceID
        append(pending)
        return false
    }

    var pendingRemovals: [HostEnrollment] {
        compactMap { host in
            host.pendingCredentialID.map { HostEnrollment(hostKey: host.hostKey, tlsDeviceID: $0) }
        }
    }

    mutating func acknowledge(_ enrollment: HostEnrollment) {
        removeAll { $0.hostKey == enrollment.hostKey && $0.pendingCredentialID == enrollment.tlsDeviceID }
    }
}

/// A JSON file in Application Support.
public struct FilePairedHostStore: PairedHostStore {
    private let file: PairedHostFile<PairedHost>
    public var url: URL { file.url }

    public init(url: URL? = nil) {
        file = PairedHostFile(url: url)
    }

    public func load() -> [PairedHost] {
        (try? file.read().filter { $0.tlsDeviceID != nil }) ?? []
    }

    public func save(_ host: PairedHost) throws {
        try file.mutate { $0.save(host) }
    }

    public func update(_ host: PairedHost) throws {
        try file.mutate { hosts in
            guard let index = hosts.firstIndex(where: {
                $0.hostKey == host.hostKey && $0.tlsDeviceID == host.tlsDeviceID && $0.pendingCredentialID == nil
            }) else { return }
            hosts[index].addresses = host.addresses
        }
    }

    public func remove(id: String) throws {
        try file.mutate { $0.removeAll { $0.id == id && $0.pendingCredentialID == nil } }
    }

    public func removeAll() throws {
        try file.mutate { $0.removeAll { $0.pendingCredentialID == nil } }
    }

    public func retire(_ enrollment: HostEnrollment) throws -> Bool {
        try file.mutate { $0.retire(enrollment) }
    }

    public func pendingRemovals() throws -> [HostEnrollment] { try file.read().pendingRemovals }

    public func acknowledgeRemoval(of enrollment: HostEnrollment) throws {
        try file.mutate { $0.acknowledge(enrollment) }
    }
}

public final class InMemoryPairedHostStore: PairedHostStore {
    private let hosts: Mutex<[PairedHost]>

    public init(_ hosts: [PairedHost] = []) { self.hosts = Mutex(hosts) }

    public func load() -> [PairedHost] { hosts.withLock { $0.filter { $0.pendingCredentialID == nil } } }
    public func save(_ host: PairedHost) throws {
        hosts.withLock { $0.save(host) }
    }
    public func update(_ host: PairedHost) throws {
        hosts.withLock { hosts in
            if let index = hosts.firstIndex(where: { $0.hostKey == host.hostKey && $0.tlsDeviceID == host.tlsDeviceID }) {
                hosts[index].addresses = host.addresses
            }
        }
    }
    public func remove(id: String) throws { hosts.withLock { $0.removeAll { $0.id == id && $0.pendingCredentialID == nil } } }
    public func removeAll() throws { hosts.withLock { $0.removeAll { $0.pendingCredentialID == nil } } }
    public func retire(_ enrollment: HostEnrollment) throws -> Bool { hosts.withLock { $0.retire(enrollment) } }
    public func pendingRemovals() throws -> [HostEnrollment] { hosts.withLock { $0.pendingRemovals } }
    public func acknowledgeRemoval(of enrollment: HostEnrollment) throws { hosts.withLock { $0.acknowledge(enrollment) } }
}
