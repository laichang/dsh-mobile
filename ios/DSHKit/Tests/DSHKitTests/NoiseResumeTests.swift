import DSHCore
import DSHTestSupport
import Foundation
import SwiftData
import Testing

/// S1 × S2 seam (S1 landed second, PLAN.md §5 S1): the durable list over `NoiseChannel`. After
/// kill/reopen the app reconnects with a fresh IK handshake and resumes from its cached cursor.
@MainActor
@Suite(.serialized) struct NoiseResumeTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s1s2-\(UUID().uuidString).store")
    let keys = InMemoryDeviceKeyStore()
    let hosts = InMemoryPairedHostStore()

    func waitUntil(_ what: String = "", timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A store as AppModel builds it for a paired host: Noise (IK reconnect) to its first address.
    func launch(_ pairing: Pairing, _ paired: PairedHost, _ transport: @escaping BridgeTransportFactory) throws -> TaskListStore {
        let connection = HostConnection(endpoint: paired.addresses[0], channel: try pairing.reconnectChannel(to: paired),
                                        transport: transport)
        #expect(connection.channelName == "noise")
        let store = TaskListStore(
            container: try TaskCache.container(url: storeURL),
            hosts: [.init(key: "noise:\(paired.id)", connection: connection)], prompt: "Count to five.")
        store.backoff = (.milliseconds(20), .milliseconds(100))
        // send() returns as soon as the host is online; under load the first connect can take
        // longer than 500 ms, and then send() gave nil (S20 review, 2026-11-07).
        store.sendWaitsFor = .seconds(5)
        return store
    }

    static let reply = ["one ", "two ", "three ", "four ", "five"]

    @Test func killAndReopenReconnectsOverNoiseAndResumesFromTheCursor() async throws {
        let noise = FakeNoiseHost()
        let bridge = FakeHost(script: .init(reply: Self.reply, chunkDelay: .milliseconds(60)))
        let transport = noise.factory(host: bridge)
        let pairing = Pairing(keys: keys, hosts: hosts, transport: transport)
        let paired = try await pairing.pair(await noise.makeOffer())

        var store: TaskListStore? = try launch(pairing, paired, transport)
        store?.foreground()
        let key = try #require(await store?.send())
        try await waitUntil("some text") { !(store?.task(key)?.transcript.isEmpty ?? true) }
        #expect(await noise.reconnects == 1)
        store?.background()
        store = nil
        try await Task.sleep(for: .milliseconds(500)) // the task finishes on the host meanwhile
        let headWhileAway = bridge.head

        let reopened = try launch(pairing, paired, transport)
        let cached = try #require(reopened.task(key))
        #expect(cached.state == .running)
        #expect(!cached.transcript.isEmpty && cached.transcript != Self.reply.joined())

        reopened.foreground()
        try await waitUntil("gap filled") { reopened.task(key)?.state == .completed }
        // A second IK handshake (no pairing step), then Resume from the cursor: the gap arrives
        // exactly once, and nothing was missed or repeated.
        #expect(await noise.reconnects == 2)
        #expect(await noise.refusals.isEmpty)
        #expect(reopened.task(key)?.transcript == Self.reply.joined())
        #expect(reopened.hosts.first?.channelName == "noise")
        #expect(reopened.hosts.first?.reachability == .online)
        #expect(bridge.head == headWhileAway) // the reopen added nothing to the host's log
    }

    @Test func pairingASecondHostPreservesTheFirstConnectionAndRoutesEachPrompt() async throws {
        let homeNoise = FakeNoiseHost(hostName: "Home Mac"), officeNoise = FakeNoiseHost(hostName: "Office Mac")
        let home = FakeHost(hostName: "Home Mac"), office = FakeHost(hostName: "Office Mac")
        let homePairing = Pairing(keys: keys, hosts: hosts, transport: homeNoise.factory(host: home))
        let officePairing = Pairing(keys: keys, hosts: hosts, transport: officeNoise.factory(host: office))
        let homeHost = try await homePairing.pair(await homeNoise.makeOffer())
        let store = try launch(homePairing, homeHost, homePairing.transport)
        store.foreground()
        defer { store.background() }
        let homeTask = try #require(await store.send())

        let officeHost = try await officePairing.pair(await officeNoise.makeOffer())
        let officeKey = "noise:\(officeHost.id)"
        let officeConnection = HostConnection(endpoint: officeHost.addresses[0],
            channel: try officePairing.reconnectChannel(to: officeHost), transport: officePairing.transport)
        store.connectPairedHost(.init(key: officeKey, connection: officeConnection, name: officeHost.name))
        #expect(hosts.load().map(\.id) == [homeHost.id, officeHost.id])
        #expect(store.composerHostKey == "noise:\(homeHost.id)")
        store.chooseHost(officeKey)
        store.prompt = "Run on office"
        let officeTask = try #require(await store.send())
        try await waitUntil("both tasks complete") {
            store.task(homeTask)?.state == .completed && store.task(officeTask)?.state == .completed
        }
        #expect(home.prompts == ["Count to five."])
        #expect(office.prompts == ["Run on office"])
        #expect(store.task(homeTask)?.hostName == "Home Mac")
        #expect(store.task(officeTask)?.hostName == "Office Mac")
        #expect(await homeNoise.reconnects == 1)
        #expect(await officeNoise.reconnects == 1)
    }

    @Test func droppedNoiseConnectionReconnectsAndReplaysOnlyTheGap() async throws {
        let noise = FakeNoiseHost()
        let bridge = FakeHost(script: .init(reply: Self.reply, chunkDelay: .milliseconds(40)))
        let transport = noise.factory(host: bridge)
        let pairing = Pairing(keys: keys, hosts: hosts, transport: transport)
        let paired = try await pairing.pair(await noise.makeOffer())
        let store = try launch(pairing, paired, transport)
        store.foreground()
        let key = try #require(await store.send())
        try await waitUntil("some text") { !(store.task(key)?.transcript.isEmpty ?? true) }
        bridge.dropConnections()
        try await waitUntil("completed") { store.task(key)?.state == .completed }
        #expect(await noise.reconnects >= 2)
        #expect(store.task(key)?.transcript == Self.reply.joined())
    }
}
