import DSHCore
import DSHFeatures
import DSHTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

/// A reconnect tries every saved address of a host. The Mac is
/// an in-process `FakeHost`; its two addresses are two routes to it (a LAN
/// address and a Tailscale one), and a route can die (refused) or go silent (no answer).
@MainActor
@Suite(.serialized) struct ReconnectTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-reconnect-\(UUID().uuidString).store")
    let hosts = InMemoryPairedHostStore()
    static let lan = HostEndpoint(host: "192.168.1.5", port: 47801)
    static let tailscale = HostEndpoint(host: "100.79.171.34", port: 47801)

    /// How each address of the Mac answers now, and how often each was tried.
    final class Routes: Sendable {
        enum State: Sendable { case up, refused, silent }
        private let states = Mutex<[String: State]>([:])
        private let tries = Mutex<[String: Int]>([:])

        func set(_ endpoint: HostEndpoint, _ state: State) { states.withLock { $0[endpoint.description] = state } }
        func tries(_ endpoint: HostEndpoint) -> Int { tries.withLock { $0[endpoint.description] ?? 0 } }

        /// The transport factory of the phone: each URL reaches the Mac through its route.
        func factory(_ mac: @escaping BridgeTransportFactory) -> BridgeTransportFactory {
            { url in
                let key = HostEndpoint(host: url.host() ?? "", port: url.port ?? 0).description
                self.tries.withLock { $0[key, default: 0] += 1 }
                switch self.states.withLock({ $0[key] ?? .up }) {
                case .up: return try await mac(url)
                case .refused: throw URLError(.cannotConnectToHost)
                case .silent: try await Task.sleep(for: .seconds(60)); throw URLError(.timedOut)
                }
            }
        }
    }

    /// Waits on the store with no polling: `waitForStore` in StoreWait.swift. A short
    /// timeout here is raised to its 30 s, so a busy machine makes the test slower, not red.
    func waitUntil(_ what: String = "", timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        await waitForStore(what, timeout: max(timeout, .seconds(30)), sourceLocation: sourceLocation, condition)
    }

    func pairedMac(_ routes: Routes) throws -> (BridgeTransportFactory, PairedHost) {
        let bridge = FakeHost(script: .init(reply: ["over ", "tailscale"], chunkDelay: .milliseconds(5)))
        var paired = PairedHost(name: "Fake Mac", addresses: [Self.lan, Self.tailscale], hostKey: [1])
        paired.tlsDeviceID = UUID().uuidString
        try hosts.save(paired)
        return (routes.factory(bridge.factory), paired)
    }

    func launch(_ factory: @escaping BridgeTransportFactory, _ paired: PairedHost) throws -> TaskListStore {
        let hosts = self.hosts
        let connection = HostConnection(endpoints: paired.addresses, transport: factory, attemptTimeout: .milliseconds(300), onAddressesChange: { addresses in
            var saved = paired
            saved.addresses = addresses
            try? hosts.update(saved)
        })
        let store = TaskListStore(cache: try TaskCache(url: storeURL),
                                  hosts: [.init(key: paired.cacheKey, connection: connection, name: paired.name)],
                                  prompt: "Which address?")
        store.backoff = (.milliseconds(20), .milliseconds(100))
        store.sendWaitsFor = .seconds(5)
        return store
    }

    /// The phone left the LAN: the reconnect finds the LAN address dead, connects over Tailscale,
    /// takes a task, and saves Tailscale first. The next launch tries Tailscale first.
    @Test func deadFirstAddressFallsThroughToTheSecondAndIsSavedFirst() async throws {
        let routes = Routes()
        let (pairing, paired) = try pairedMac(routes)
        routes.set(Self.lan, .silent)

        let store = try launch(pairing, paired)
        store.foreground()
        try await waitUntil("online") { store.hosts.first?.reachability == .online }
        #expect(store.hosts.first?.address == Self.tailscale)
        #expect(store.hosts.first?.addressFailures == [])
        #expect(hosts.load().first?.addresses == [Self.tailscale, Self.lan])
        let key = try #require(await store.send())
        try await waitUntil("completed") { store.task(key)?.state == .completed }
        #expect(store.task(key)?.transcript == "over tailscale")
        store.background()

        let lanTries = routes.tries(Self.lan)
        let reopened = try launch(pairing, try #require(hosts.load().first))
        reopened.foreground()
        defer { reopened.background() }
        try await waitUntil("online again") { reopened.hosts.first?.reachability == .online }
        #expect(reopened.hosts.first?.address == Self.tailscale)
        #expect(routes.tries(Self.lan) == lanTries) // Tailscale first: the LAN address was not tried
    }

    /// Every address fails: the host is offline, with the last error of each address. The saved
    /// order stays as it was.
    @Test func allAddressesDeadShowTheHostOfflineWithTheErrorOfEach() async throws {
        let routes = Routes()
        let (pairing, paired) = try pairedMac(routes)
        routes.set(Self.lan, .refused)
        routes.set(Self.tailscale, .silent)

        let store = try launch(pairing, paired)
        store.foreground()
        defer { store.background() }
        try await waitUntil("offline") { store.hosts.first?.reachability == .offline }
        try await waitUntil("each error") { store.hosts.first?.addressFailures.count == 2 }
        #expect(store.hosts.first?.addressFailures == [
            AddressFailure(endpoint: Self.lan, reason: "URL error -1004, connection refused", kind: .nothingListens),
            AddressFailure(endpoint: Self.tailscale, reason: "no answer in 0.3 s", kind: .notReachable),
        ])
        #expect(store.allHostsOffline)
        #expect(hosts.load().first?.addresses == [Self.lan, Self.tailscale])

        // The LAN is back: the next try connects there, and the errors go.
        routes.set(Self.lan, .up)
        store.foreground()
        try await waitUntil("online", timeout: .seconds(10)) { store.hosts.first?.reachability == .online }
        #expect(store.hosts.first?.address == Self.lan)
        #expect(store.hosts.first?.addressFailures == [])
    }

    /// A host that revoked this phone (close 4003) says so at any address: the search ends
    /// there, and the other address is not tried.
    @Test func revokedAtTheFirstAddressDoesNotTryTheNext() async throws {
        let routes = Routes()
        let connection = HostConnection(endpoints: [Self.lan, Self.tailscale], transport: routes.factory { _ in
            throw HostConnectionError.deviceRevoked
        })
        await #expect(throws: HostConnectionError.deviceRevoked) { try await connection.connect() }
        #expect(await connection.deviceRevoked)
        #expect(routes.tries(Self.lan) == 1)
        #expect(routes.tries(Self.tailscale) == 0)
    }

}
