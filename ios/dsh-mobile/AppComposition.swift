import DSHCore
import Foundation
import SwiftData
#if DEBUG
import DSHTestSupport
#endif

/// Each paired host syncs over its own Noise connection into the shared task list.
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
    private(set) var hasSavedHosts = false
    private static let preferredHostKey = "dshm.composerHostKey"
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
        if options.resetStore {
            try? TaskCache.erase(container)
            UserDefaults.standard.removeObject(forKey: Self.preferredHostKey)
        }
        if options.useFakeBridge { transport = FakeBridge.factory() }
        presetPrompt = options.presetPrompt ?? ""
        if let seconds = options.connectDelay { connectDelay = .milliseconds(Int(seconds * 1000)) }
        #endif
        pairing = Pairing(keys: keys, hosts: hosts, transport: transport)
        store = makeStore()
    }

    private func makeStore() -> TaskListStore? {
        let hosts = hostConfigs()
        guard !hosts.isEmpty else { return nil }
        return TaskListStore(container: container, hosts: hosts, prompt: presetPrompt, firstConnectDelay: connectDelay,
                             preferredHostKey: UserDefaults.standard.string(forKey: Self.preferredHostKey)) { key in
            UserDefaults.standard.set(key, forKey: Self.preferredHostKey)
        }
    }

    func retrySavedHosts() {
        store = makeStore()
        store?.foreground()
    }

    private func pairedConfig(_ host: PairedHost) -> TaskListStore.HostConfig? {
        guard let endpoint = host.addresses.first, let channel = try? pairing.reconnectChannel(to: host) else { return nil }
        return .init(key: "noise:\(host.id)", connection: HostConnection(endpoint: endpoint, channel: channel,
                     transport: pairing.transport), name: host.name.isEmpty ? endpoint.description : host.name)
    }

    private func hostConfigs() -> [TaskListStore.HostConfig] {
        #if DEBUG
        let options = DebugLaunchOptions.parse(ProcessInfo.processInfo.arguments)
        if let drawer = options.fakeDrawer.flatMap(FakeDrawer.Variant.init(rawValue:)) { return FakeDrawer.hosts(drawer) }
        if options.multipleFakeHosts {
            return ["Office Mac", "Home Mac"].enumerated().map { index, name in
                let endpoint = HostEndpoint.localBridge(port: 47801 + index)
                var script = FakeBridge.Script(reply: ["Reply ", "from ", name], chunkDelay: .seconds(1))
                script.holdPrompt = options.fakeHold
                let fake = FakeHost(script: script,
                                    hostName: name, reachable: index != 0 || !options.fakeBridgeOffline,
                                    approvals: options.fakeApprovals ? FakeApprovals.seed(for: name) : [])
                return .init(key: "fake:\(name)", connection: HostConnection(endpoint: endpoint,
                             channel: PlaintextChannel(), transport: fake.factory), name: name)
            }
        }
        if options.useFakeBridge {
            let endpoint = HostEndpoint.localBridge()
            var script: FakeBridge.Script = options.fakeMilestones ? .threeTodos() : .init()
            if options.fakeScenario == "coding" { script = .codingTask() } // S16
            script.holdPrompt = options.fakeHold
            let fake = FakeHost(script: script, reachable: !options.fakeBridgeOffline)
            return [.init(key: "fake:\(endpoint)",
                          connection: HostConnection(endpoint: endpoint, channel: PlaintextChannel(), transport: fake.factory))]
        }
        #endif
        let paired = pairing.hosts.load()
        hasSavedHosts = !paired.isEmpty
        if !paired.isEmpty { return paired.compactMap(pairedConfig) }
        #if DEBUG
        let endpoint = HostEndpoint.localBridge(port: options.bridgePort ?? 47801)
        return [.init(key: "bridge:\(endpoint)",
                      connection: HostConnection(endpoint: endpoint, channel: PlaintextChannel(), transport: pairing.transport))]
        #else
        return []
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
            if let store, store.hosts.contains(where: { $0.channelName == "noise" }), let config = pairedConfig(paired) {
                store.connectPairedHost(config)
            } else {
                store?.background()
                store = makeStore()
                store?.foreground()
            }
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
