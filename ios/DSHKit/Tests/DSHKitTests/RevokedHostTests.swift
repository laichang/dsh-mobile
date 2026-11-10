import DSHCore
import DSHTestSupport
import Foundation
import Testing

/// A host that refuses this device (WebSocket close 4003 device unknown) revoked it.
/// That is final: the store drops the host and does not retry it. A host that is only offline
/// is retried as before. The fake closes like the bridge: the revoke response first, then 4003,
/// and a new connection is refused with 4003 (bridge/src/server.ts, pairing/handshake.ts).
@MainActor
@Suite(.serialized) struct RevokedHostTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s29-\(UUID().uuidString).store")
    static let mac = "fake:\(FakeHosts.macName)"
    static let office = "fake:\(FakeHosts.officeName)"

    /// Waits on the store with no polling: `waitForStore` in StoreWait.swift. A short
    /// timeout here is raised to its 30 s, so a busy machine makes the test slower, not red.
    func waitUntil(_ what: String, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        await waitForStore(what, timeout: max(timeout, .seconds(30)), sourceLocation: sourceLocation, condition)
    }

    /// Polls a fake host's own state, which is not observable. Store state uses `waitUntil`.
    func pollUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func launch(_ variant: FakeHosts.Variant) throws -> (TaskListStore, [FakeHost]) {
        let (configs, switchable) = FakeHosts.hosts(variant)
        let store = TaskListStore(container: try TaskCache.container(url: storeURL), hosts: configs)
        store.backoff = (.milliseconds(20), .milliseconds(40))
        return (store, switchable)
    }

    /// Another client revokes this phone: the host closes with 4003 and refuses it. The store
    /// says so once and drops the host; it makes no new attempt. The offline host keeps retrying.
    @Test func aHostThatClosesWith4003IsRevokedAndNotRetriedButAnOfflineHostIs() async throws {
        let (store, switchable) = try launch(.three)
        let (mac, office) = (switchable[0], switchable[1])
        var revoked: [String] = []
        store.onHostRevoked = { revoked.append($0.key) }
        store.foreground()
        try await waitUntil("both online") {
            store.hosts.filter { $0.reachability == .online }.map(\.key) == [Self.mac, Self.office]
        }

        office.setReachable(false)
        mac.revokeThisDevice()
        try await waitUntil("MacBook-Pro is gone") { !store.hosts.contains { $0.key == Self.mac } }
        #expect(revoked == [Self.mac])
        #expect(store.revokedHosts.map(\.key) == [Self.mac])

        let macAttempts = mac.connectAttempts
        let officeAttempts = office.connectAttempts
        try await pollUntil("an offline host is retried") { office.connectAttempts > officeAttempts + 2 }
        #expect(mac.connectAttempts == macAttempts, "a revoked host is not retried")
        #expect(store.hosts.first { $0.key == Self.office }?.reachability != .online)
        store.foreground() // a wake does not bring it back either
        try await Task.sleep(for: .milliseconds(100))
        #expect(mac.connectAttempts == macAttempts)
        #expect(revoked == [Self.mac], "said once")
    }

    /// The revoke from this phone: the response arrives, then the close 4003. The store drops
    /// the host, also when the response is lost (the host only refuses after that).
    @Test func aRevokeOfThisDeviceDropsTheHostAndAReconnectRefusedWith4003DoesToo() async throws {
        let (store, switchable) = try launch(.one)
        store.foreground()
        try await waitUntil("online") { store.hosts.first?.reachability == .online }
        let connection = try #require(store.deviceManagement(for: Self.mac))
        let list = try await connection.revokeDevice(FakeHosts.thisDevice)
        #expect(list.devices.map(\.id) == [FakeHosts.otherDevice])
        try await waitUntil("no host left") { store.hosts.isEmpty }
        #expect(store.revokedHosts.map(\.name) == [FakeHosts.macName])
        let attempts = switchable[0].connectAttempts
        try await Task.sleep(for: .milliseconds(300))
        #expect(switchable[0].connectAttempts == attempts)
    }

    /// The same at launch: the device was revoked while the app was closed, so the first
    /// connection is refused with 4003.
    @Test func aHostThatRefusesTheFirstConnectionWith4003IsRevoked() async throws {
        let (store, switchable) = try launch(.one)
        switchable[0].revokeThisDevice()
        store.foreground()
        try await waitUntil("refused") { store.hosts.isEmpty }
        #expect(switchable[0].connectAttempts == 1)
        #expect(store.revokedHosts.map(\.key) == [Self.mac])
    }
}
