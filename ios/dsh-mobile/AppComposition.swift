import DSHCore
import Foundation
import SwiftData
#if DEBUG
import DSHTestSupport
#endif

/// Builds the object graph and swaps it when pairing changes (PLAN S1), around S2's durable
/// task list: one `TaskListStore` over the SwiftData cache, with one host.
/// - A paired host: Noise (`IK` reconnect) over a WebSocket to its first address. Every
///   reconnect runs a fresh IK handshake, then `Resume` from the cached cursor (S1 x S2 seam).
/// - No paired host, Release: nothing to talk to; the app asks to pair.
/// - No paired host, Debug: T0's plaintext dev path to the bridge on this Mac's loopback.
/// S9 replaces "one host" with every paired host.
@MainActor
@Observable
final class AppModel {
    /// What the pairing screen shows: a parsed offer, or why a code couldn't be read.
    enum PairingRoute: Identifiable {
        case offer(PairingModel)
        case invalid(String)

        var id: String {
            switch self {
            case .offer(let m): "offer-\(m.offer.offerID)"
            case .invalid(let why): "invalid-\(why)"
            }
        }
    }

    private(set) var store: TaskListStore?
    private(set) var host: PairedHost?
    var pairingRoute: PairingRoute?
    var showingScanner = false

    let pairing: Pairing
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var presetPrompt = ""
    @ObservationIgnored private var connectDelay: Duration = .zero

    init() {
        let keys = KeychainDeviceKeyStore()
        let hosts = FilePairedHostStore()
        var transport: BridgeTransportFactory = WebSocketTransport.factory
        container = Self.makeContainer()
        #if DEBUG
        let options = DebugLaunchOptions.parse(ProcessInfo.processInfo.arguments)
        if options.resetPairing {
            try? hosts.removeAll()
            try? keys.reset()
        }
        if options.resetStore { try? TaskCache.erase(container) }
        if options.useFakeBridge { transport = FakeBridge.factory() }
        presetPrompt = options.presetPrompt ?? ""
        if let seconds = options.connectDelay { connectDelay = .milliseconds(Int(seconds * 1000)) }
        #endif
        pairing = Pairing(keys: keys, hosts: hosts, transport: transport)
        host = hosts.load().last
        store = makeStore()
    }

    var hostLabel: String {
        if let host { return host.name.isEmpty ? host.addresses.first?.description ?? "host" : host.name }
        return "this Mac (dev, loopback)"
    }

    private func makeStore() -> TaskListStore? {
        guard let config = makeHost() else { return nil }
        return TaskListStore(container: container, hosts: [config], prompt: presetPrompt, firstConnectDelay: connectDelay)
    }

    /// The one host this build talks to, keyed for the cache (`<kind>:<who>`).
    private func makeHost() -> TaskListStore.HostConfig? {
        #if DEBUG
        let options = DebugLaunchOptions.parse(ProcessInfo.processInfo.arguments)
        if options.useFakeBridge {
            let endpoint = HostEndpoint.localBridge()
            let fake = FakeHost(script: options.fakeMilestones ? .threeTodos() : .init(), reachable: !options.fakeBridgeOffline)
            return .init(key: "fake:\(endpoint)",
                         connection: HostConnection(endpoint: endpoint, channel: PlaintextChannel(), transport: fake.factory))
        }
        #endif
        if let host, let endpoint = host.addresses.first, let channel = try? pairing.reconnectChannel(to: host) {
            return .init(key: "noise:\(host.id)",
                         connection: HostConnection(endpoint: endpoint, channel: channel, transport: pairing.transport))
        }
        #if DEBUG
        let endpoint = HostEndpoint.localBridge(port: options.bridgePort ?? 47801)
        return .init(key: "bridge:\(endpoint)",
                     connection: HostConnection(endpoint: endpoint, channel: PlaintextChannel(), transport: pairing.transport))
        #else
        return nil
        #endif
    }

    /// A scanned QR payload, a pasted link, or (Debug) a `dshm://pair?…` deep link.
    func openPairingCode(_ text: String) {
        showingScanner = false
        do {
            pairingRoute = .offer(PairingModel(offer: try PairingOffer(string: text), pairing: pairing))
        } catch {
            pairingRoute = .invalid(error.description)
        }
    }

    func closePairing() {
        if case .offer(let model)? = pairingRoute, case .paired(let paired) = model.state {
            host = paired
            // The old store's connection goes; the new one starts syncing right away (the scene
            // is already active, so no scene-phase change will start it).
            store?.background()
            store = makeStore()
            store?.foreground()
        }
        pairingRoute = nil
    }

    /// The cache on disk; if it can't be opened (e.g. an incompatible schema in a dev build),
    /// start from an empty one rather than not at all. The host is the source of truth (D9).
    private static func makeContainer() -> ModelContainer {
        if let container = try? TaskCache.container() { return container }
        let url = URL.applicationSupportDirectory.appending(path: "default.store")
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(filePath: url.path() + suffix))
        }
        if let container = try? TaskCache.container() { return container }
        return try! TaskCache.container(inMemory: true)
    }
}
