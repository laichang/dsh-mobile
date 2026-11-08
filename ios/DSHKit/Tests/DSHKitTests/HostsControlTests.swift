import DSHCore
import DSHTestSupport
import Foundation
import Testing

/// S21 · hosts and control: the all-offline state of 01 (X3), and the devices, audit records and
/// revoke of one host (X2) against `FakeHosts`.
@MainActor
@Suite(.serialized) struct HostsControlTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s21-\(UUID().uuidString).store")

    /// Waits on the store with no polling (S12): `waitForStore` in StoreWait.swift. A short
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
        #expect(store.hosts.first?.capabilities.contains(FakeDevices.capability) == true)

        for host in switchable { host.setReachable(false) }
        try await waitUntil("all offline") { store.allHostsOffline }
        store.prompt = "Summarize the Q3 report"
        #expect(!store.canSend)
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
        #expect(list.currentDeviceID == FakeHosts.thisDevice)
        #expect(list.devices.map(\.id) == [FakeHosts.thisDevice, FakeHosts.otherDevice])

        let first = try await connection.audit()
        #expect(first.entries.map(\.id) == ["audit-3", "audit-2"])
        let older = try await connection.audit(beforeID: first.nextBeforeID)
        #expect(older.entries.map(\.id) == ["audit-1"])
        #expect(older.nextBeforeID.isEmpty)

        let afterOther = try await connection.revokeDevice(FakeHosts.otherDevice)
        #expect(afterOther.devices.map(\.id) == [FakeHosts.thisDevice])
        #expect(store.hosts.first?.reachability == .online)

        let afterSelf = try await connection.revokeDevice(FakeHosts.thisDevice)
        #expect(afterSelf.devices.isEmpty)
        // S29: the host closes with 4003 and refuses this device; the store drops it for good.
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
}
