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

    func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
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
        try await waitUntil("refused") { store.hosts.first?.reachability == .offline }
        // A revoked device cannot connect again, even when the host is reachable.
        switchable[0].setReachable(true)
        store.foreground()
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.hosts.first?.reachability != .online)
        #expect(store.allHostsOffline)
    }
}
