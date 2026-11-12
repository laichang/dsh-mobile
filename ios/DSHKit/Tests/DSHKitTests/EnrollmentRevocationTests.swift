@testable import DSHCore
import DSHFeatures
import DSHTestSupport
import DSHTransport
import Foundation
import Testing

@MainActor
struct EnrollmentRevocationTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var hosts: FilePairedHostStore { FilePairedHostStore(url: dir.appending(path: "hosts.json")) }

    func register(_ id: String, key: UInt8 = 1) throws -> PairedHost {
        var host = PairedHost(name: id, addresses: [.localBridge()], hostKey: [key])
        host.tlsDeviceID = id
        try hosts.save(host)
        try Data(id.utf8).write(to: dir.appending(path: id))
        return host
    }

    func deleteKey(_ origin: HostEnrollment) throws {
        do { try FileManager.default.removeItem(at: dir.appending(path: origin.tlsDeviceID)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }

    func config(_ host: PairedHost, _ peer: FakeHost) throws -> TaskListStore.HostConfig {
        let origin = try #require(host.enrollment)
        let key = dir.appending(path: origin.tlsDeviceID)
        let connection = HostConnection(endpoints: host.addresses, enrollment: origin) { url in
            guard try Data(contentsOf: key) == Data(origin.tlsDeviceID.utf8) else {
                throw URLError(.userAuthenticationRequired)
            }
            return try await peer.factory(url)
        }
        return .init(key: host.cacheKey, connection: connection, name: host.name)
    }

    @Test(arguments: [false, true])
    func delayedRevokeCannotDismissOrDisconnectNewPairing(remote: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try register(FakeHosts.thisDevice)
        let peerA = FakeHost(hostName: "A", devices: FakeHosts.macDevices())
        let cache = try TaskCache(url: dir.appending(path: "tasks.store"))
        let store = TaskListStore(cache: cache, hosts: [try config(a, peerA)])
        var remoteSignal: HostEnrollment?
        store.onHostRevoked = { remoteSignal = $0.enrollment }
        store.foreground()
        defer { store.background() }
        try await waitForStore("A online") { store.hosts.first?.reachability == .online }

        let signal: HostEnrollment
        if remote {
            peerA.revokeThisDevice()
            try await waitForStore("A refused") { store.revokedHosts.count == 1 }
            signal = try #require(remoteSignal)
        } else {
            let commands = try #require(store.deviceManagement(for: a.cacheKey))
            let current = try #require(try await commands.listDevices().first { $0.isCurrent })
            guard case .thisDevice(let origin) = try await commands.revokeDevice(current) else {
                Issue.record("missing local revoke result"); return
            }
            signal = origin
        }
        #expect(signal == a.enrollment)
        let b = try register("B"), peerB = FakeHost(hostName: "B", devices: FakeHosts.macDevices())
        let newConfig = try config(b, peerB)
        store.connectPairedHost(newConfig)
        try await waitForStore("replacement online") { store.hosts.first?.reachability == .online && store.hosts.first?.enrollment == b.enrollment }

        var forgotten = ForgottenEnrollments()
        let attempts = peerB.connectAttempts
        let pairing = Pairing(hosts: hosts)
        // Both sheets use this result to decide whether to replace the open page.
        #expect(try !forgotten.forget(signal) { try pairing.forget($0, deletingCredential: deleteKey) })
        store.forget(signal)
        #expect(store.hosts.first?.enrollment == newConfig.enrollment)
        #expect(!forgotten.enrollments.contains(newConfig.enrollment))
        #expect(hosts.load() == [b])
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: signal.tlsDeviceID).path))
        #expect(try await newConfig.connection.listTasks().hostName == "B")
        #expect(peerB.connectAttempts == attempts)

        store.background()
        let reopened = try #require(hosts.load().first)
        let newConnection = try config(reopened, peerB).connection
        try await newConnection.connect()
        #expect(try await newConnection.listTasks().hostName == "B")
        await newConnection.disconnect()
    }

    @Test(arguments: [false, true])
    func bothSourcesDeduplicateOnlyThisRegistration(closeFirst: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try register(FakeHosts.thisDevice)
        var devices = FakeHosts.macDevices()
        devices.closeBeforeRevokeResponse = closeFirst
        let peer = FakeHost(hostName: "A", devices: devices)
        let config = try config(a, peer)
        let store = TaskListStore(cache: try TaskCache(url: dir.appending(path: "tasks.store")), hosts: [config])
        var remote: HostEnrollment?
        store.onHostRevoked = { remote = $0.enrollment }
        store.foreground()
        defer { store.background() }
        try await waitForStore("A online") { store.hosts.first?.reachability == .online }
        let commands = try #require(store.deviceManagement(for: a.cacheKey))
        let device = try #require(try await commands.listDevices().first { $0.isCurrent })
        guard case .thisDevice(let local) = try await commands.revokeDevice(device) else {
            Issue.record("missing local revoke"); return
        }
        try await waitForStore("remote revoke") { store.revokedHosts.count == 1 }
        let close = try #require(remote)
        let signals = closeFirst ? [close, local] : [local, close]
        var forgotten = ForgottenEnrollments()
        var actions = [Bool]()
        let pairing = Pairing(hosts: hosts)
        for signal in signals + signals {
            actions.append(try forgotten.forget(signal) { try pairing.forget($0, deletingCredential: deleteKey) })
        }
        #expect(actions == [true, false, false, false])
        let b = try register("B")
        #expect(try forgotten.forget(#require(b.enrollment)) { try pairing.forget($0, deletingCredential: deleteKey) })
    }

    @Test(arguments: [false, true])
    func restartFinishesOnlyPendingCredential(keyAlreadyRemoved: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try register("A"), other = try register("other", key: 2)
        let origin = try #require(a.enrollment)
        #expect(try hosts.retire(origin))
        if keyAlreadyRemoved { try deleteKey(origin) }
        let b = try register("B")
        let restarted = Pairing(hosts: hosts)
        #expect(throws: CocoaError.self) {
            try restarted.retryPendingRemovals { _ in throw CocoaError(.fileWriteNoPermission) }
        }
        #expect(try hosts.pendingRemovals() == [origin])
        var retried: [HostEnrollment] = []
        try restarted.retryPendingRemovals { retried.append($0); try deleteKey($0) }
        #expect(retried == [origin])
        #expect(try hosts.pendingRemovals().isEmpty)
        #expect(hosts.load() == [other, b])
        for host in hosts.load() {
            let connection = try config(host, FakeHost(hostName: host.name)).connection
            try await connection.connect()
            #expect(try await connection.listTasks().hostName == host.name)
            await connection.disconnect()
        }
    }
}
