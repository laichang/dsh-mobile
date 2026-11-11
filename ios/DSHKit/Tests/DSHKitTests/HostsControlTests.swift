import DSHCore
import DSHTestSupport
import Foundation
import Testing

/// Hosts and control: the all-offline state of 01 (X3), and the devices, audit records and
/// revoke of one host (X2) against `FakeHosts`.
@MainActor
@Suite(.serialized) struct HostsControlTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s21-\(UUID().uuidString).store")

    /// Waits on the store with no polling: `waitForStore` in StoreWait.swift. A short
    /// timeout here is raised to its 30 s, so a busy machine makes the test slower, not red.
    func waitUntil(_ what: String, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        await waitForStore(what, timeout: max(timeout, .seconds(30)), sourceLocation: sourceLocation, condition)
    }

    func launch(_ variant: FakeHosts.Variant) throws -> (TaskListStore, [FakeHost]) {
        let (configs, switchable) = FakeHosts.hosts(variant)
        let store = TaskListStore(container: try TaskCache.container(url: storeURL), hosts: configs)
        store.backoff = (.milliseconds(20), .milliseconds(100))
        return (store, switchable)
    }

    @Test func allHostsOfflineOnlyWhenNoHostCanTakeATaskAndNotWhileOneComesBack() async throws {
        let (store, switchable) = try launch(.three)
        #expect(!store.allHostsOffline)
        store.foreground()
        try await waitUntil("hk-1 needs an update, the others are online") {
            store.hosts.map(\.reachability.token) == ["online", "bridgeUpdateRequired", "online"]
        }
        #expect(!store.allHostsOffline)
        #expect(store.deviceManagement(for: "fake:\(FakeHosts.macName)") != nil)
        #expect(store.deviceManagement(for: "fake:\(FakeHosts.officeName)") == nil)
        // MacBook-Pro sends its model catalog; screen H shows the default model.
        let mac = "fake:\(FakeHosts.macName)"
        try await waitUntil("MacBook-Pro's catalog") { store.catalogs[mac] != nil }
        let catalog = try #require(store.catalogs[mac])
        let selection = try #require(catalog.defaultSelection)
        #expect(catalog.entry(for: selection)?.name == FakeHosts.defaultModelName)

        for host in switchable { host.setReachable(false) }
        try await waitUntil("all offline") { store.allHostsOffline }
        store.prompt = "Summarize the Q3 report"
        #expect(!store.canSend)
        #expect(store.deviceManagement(for: mac) == nil)
        #expect(store.hosts.allSatisfy { $0.lastConnectedAt != nil || $0.name == FakeHosts.hkName })
        // Retries (connecting) do not clear it.
        for _ in 0..<20 {
            #expect(store.allHostsOffline)
            try await Task.sleep(for: .milliseconds(10))
        }

        switchable[0].setReachable(true)
        store.foreground()
        try await waitUntil("one host back") { !store.allHostsOffline }
        #expect(store.canSend)
        #expect(store.hosts.first?.reachability == .online)
    }

    @Test func devicesAuditPagesAndARevokeOfThisDeviceEndsItsAccess() async throws {
        let (store, switchable) = try launch(.one)
        store.foreground()
        try await waitUntil("online") { store.hosts.first?.reachability == .online }
        let connection = try #require(store.deviceManagement(for: "fake:\(FakeHosts.macName)"))

        let list = try await connection.listDevices()
        let current = try #require(list.first { $0.isCurrent })
        let other = try #require(list.first { !$0.isCurrent })
        #expect(current.id == FakeHosts.thisDevice)
        #expect(list.map(\.id) == [FakeHosts.thisDevice, FakeHosts.otherDevice])

        let first = try await connection.audit()
        #expect(first.entries.map(\.id) == ["audit-3", "audit-2"])
        #expect(first.entries.map(\.actor) == ["owner", "owner"])
        #expect(first.entries.map(\.device) == [FakeHosts.thisDevice, "web"])
        #expect(first.nextBeforeID == "audit-2")
        let older = try await connection.audit(beforeID: first.nextBeforeID)
        #expect(older.entries.map(\.id) == ["audit-1"])
        #expect(older.nextBeforeID.isEmpty)

        guard case .remaining(let afterOther) = try await connection.revokeDevice(other) else {
            Issue.record("revoking another device removed this phone"); return
        }
        #expect(afterOther.map(\.id) == [FakeHosts.thisDevice])
        #expect(store.hosts.first?.reachability == .online)

        guard case .thisDevice = try await connection.revokeDevice(current) else {
            Issue.record("self-revocation kept this phone"); return
        }
        // The host closes with 4003 and refuses this device; the store drops it for good.
        try await waitUntil("refused and dropped") { store.hosts.isEmpty }
        #expect(store.revokedHosts.map(\.name) == [FakeHosts.macName])
        // A revoked device cannot connect again, even when the host is reachable.
        let attempts = switchable[0].connectAttempts
        switchable[0].setReachable(true)
        store.foreground()
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.hosts.isEmpty)
        #expect(switchable[0].connectAttempts == attempts)
    }

    @Test func selfRevokeRecognizesDeviceRefusalBeforeResponse() async throws {
        var devices = FakeHosts.macDevices()
        devices.closeBeforeRevokeResponse = true
        let host = FakeHost(devices: devices)
        let connection = HostConnection(endpoint: .localBridge(port: 47801), transport: host.factory)
        try await connection.connect()
        let list = try await connection.listDevices()
        let current = try #require(list.first { $0.isCurrent })
        guard case .thisDevice = try await connection.revokeDevice(current) else {
            Issue.record("self-revocation did not recognize the close"); return
        }
        #expect(await connection.deviceRevoked)
    }
}
