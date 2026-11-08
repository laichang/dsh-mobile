import DSHCore
import DSHTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

/// A reconnect tries every saved address of a host (ARCHITECTURE D98, amends D21 e). The Mac is
/// a `FakeNoiseHost` in front of a `FakeHost`; its two addresses are two routes to it (a LAN
/// address and a Tailscale one), and a route can die (refused) or go silent (no answer).
@MainActor
@Suite(.serialized) struct ReconnectTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-reconnect-\(UUID().uuidString).store")
    let keys = InMemoryDeviceKeyStore()
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
                case .silent: return SilentTransport()
                }
            }
        }
    }

    /// An address that takes the connection and never answers (a LAN address off the LAN).
    final class SilentTransport: BridgeTransport {
        private let closed = AsyncStream<Void>.makeStream()

        func send(_ message: Data) async throws {}
        func receive() async throws -> Data {
            for await _ in closed.stream {}
            throw URLError(.networkConnectionLost)
        }
        func close() async { closed.continuation.finish() }
    }

    /// Waits on the store with no polling (S12): `waitForStore` in StoreWait.swift. A short
    /// timeout here is raised to its 30 s, so a busy machine makes the test slower, not red.
    func waitUntil(_ what: String = "", timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        await waitForStore(what, timeout: max(timeout, .seconds(30)), sourceLocation: sourceLocation, condition)
    }

    /// The Mac, paired over its LAN address first: saved as [LAN, Tailscale].
    func pairedMac(_ routes: Routes, reply: [String] = ["over ", "tailscale"]) async throws
        -> (Pairing, PairedHost, FakeNoiseHost) {
        let noise = FakeNoiseHost()
        let bridge = FakeHost(script: .init(reply: reply, chunkDelay: .milliseconds(5)))
        let pairing = Pairing(keys: keys, hosts: hosts, transport: routes.factory(noise.factory(host: bridge)))
        let paired = try await pairing.pair(await noise.makeOffer(addresses: [Self.lan, Self.tailscale]))
        #expect(paired.addresses == [Self.lan, Self.tailscale])
        return (pairing, paired, noise)
    }

    /// A store as `AppModel` builds it for a paired host (`Pairing.connection(to:)`).
    func launch(_ pairing: Pairing, _ paired: PairedHost) throws -> TaskListStore {
        let connection = try pairing.connection(to: paired, attemptTimeout: .milliseconds(300))
        let store = TaskListStore(container: try TaskCache.container(url: storeURL),
                                  hosts: [.init(key: "noise:\(paired.id)", connection: connection, name: paired.name)],
                                  prompt: "Which address?")
        store.backoff = (.milliseconds(20), .milliseconds(100))
        store.sendWaitsFor = .seconds(5)
        return store
    }

    /// The phone left the LAN: the reconnect finds the LAN address dead, connects over Tailscale,
    /// takes a task, and saves Tailscale first. The next launch tries Tailscale first.
    @Test func deadFirstAddressFallsThroughToTheSecondAndIsSavedFirst() async throws {
        let routes = Routes()
        let (pairing, paired, noise) = try await pairedMac(routes)
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
        #expect(await noise.refusals.isEmpty)
    }

    /// Every address fails: the host is offline, with the last error of each address. The saved
    /// order stays as it was.
    @Test func allAddressesDeadShowTheHostOfflineWithTheErrorOfEach() async throws {
        let routes = Routes()
        let (pairing, paired, _) = try await pairedMac(routes)
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

    /// A host that revoked this phone (close 4003, D82) says so at any address: the search ends
    /// there, and the other address is not tried.
    @Test func revokedAtTheFirstAddressDoesNotTryTheNext() async throws {
        let routes = Routes()
        let noise = FakeNoiseHost()
        let stranger = Pairing(keys: InMemoryDeviceKeyStore(), hosts: InMemoryPairedHostStore(),
                               transport: routes.factory(noise.factory()))
        let unknown = PairedHost(name: "Fake Mac", addresses: [Self.lan, Self.tailscale], hostKey: noise.hostKey.publicKey)
        let connection = try stranger.connection(to: unknown, attemptTimeout: .milliseconds(300))
        await #expect(throws: NoiseChannelError.deviceUnknown) { try await connection.connect() }
        #expect(await connection.deviceRevoked)
        #expect(routes.tries(Self.lan) == 1)
        #expect(routes.tries(Self.tailscale) == 0)
    }

    /// Pairing uses the same loop: a silent first address in the QR costs one timeout, not 60 s.
    @Test func pairingFallsThroughASilentAddress() async throws {
        let routes = Routes()
        routes.set(Self.lan, .silent)
        let noise = FakeNoiseHost()
        let pairing = Pairing(keys: keys, hosts: hosts, transport: routes.factory(noise.factory()))
        let clock = ContinuousClock()
        let start = clock.now
        let paired = try await pairing.pair(await noise.makeOffer(addresses: [Self.lan, Self.tailscale]))
        #expect(paired.addresses == [Self.tailscale, Self.lan])
        #expect(clock.now - start < HostConnection.defaultAttemptTimeout + .seconds(2))
    }
}
