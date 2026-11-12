@testable import DSHCore
import DSHTransport
import Foundation
import Security
import Testing

struct DirectPairingTests {
    static var directory: URL {
        URL(filePath: ProcessInfo.processInfo.environment["DSHM_PAIRING_FIXTURE"]!)
    }
    static var store: FilePairedHostStore { .init(url: directory.appending(path: "hosts.json")) }
    static func offer(_ index: Int) throws -> PairingOffer {
        try PairingOffer(string: String(contentsOf: directory.appending(path: "offer-\(index)"), encoding: .utf8))
    }
    static func key(_ origin: HostEnrollment) -> KeychainData {
        Pairing.credential(pin: origin.hostKey, deviceID: origin.tlsDeviceID)
    }
    func reconnect(_ pairing: Pairing, _ host: PairedHost) async throws {
        let connection = try pairing.connection(to: host)
        try await connection.connect()
        #expect(!(try await connection.listTasks()).logID.isEmpty)
        await connection.disconnect()
    }

    @Test func terminateWhileReplacing() async throws {
        _ = try await #require(processExitsWith: .exitCode(42)) {
            let pairing = Pairing(hosts: Self.store)
            _ = try await pairing.pair(Self.offer(1))
            _ = try await pairing.enroll(Self.offer(2)) { _ in _exit(42) }
        }
    }

    @Test func restartAndRetryWithLockedKeychain() async throws {
        let pairing = Pairing(hosts: Self.store)
        let old = try #require(Self.store.pendingRemovals().only)
        let replacement = try #require(Self.store.load().only)
        #expect(old != replacement.enrollment)
        #expect(try Self.key(old).read() != nil)
        try pairing.retryPendingRemovals()
        #expect(try Self.key(old).read() == nil)
        #expect(try Self.store.pendingRemovals().isEmpty)
        try await reconnect(pairing, replacement)

        let locked = try await pairing.enroll(Self.offer(3)) { _ in throw KeychainDataError.keychain(errSecInteractionNotAllowed) }
        defer { if let origin = locked.enrollment { try? pairing.forget(origin) } }
        let pending = try #require(Self.store.pendingRemovals().only)
        #expect(pending == replacement.enrollment)
        #expect(Self.store.load() == [locked])
        #expect(try Self.key(pending).read() != nil)
        try await reconnect(pairing, locked)
        // A prior cleanup can delete the key and exit before acknowledging it.
        try Self.key(pending).reset()
        try pairing.retryPendingRemovals()
        #expect(try Self.store.pendingRemovals().isEmpty)
        #expect(try Self.key(pending).read() == nil)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
