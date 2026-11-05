import DSHCore
import Foundation
#if DEBUG
import DSHTestSupport
#endif

/// Builds the object graph and swaps it when pairing changes (PLAN S1).
/// - A paired host: Noise (`IK` reconnect) over a WebSocket to its first address.
/// - No paired host, Release: nothing to talk to; the app asks to pair.
/// - No paired host, Debug: T0's plaintext dev path to the bridge on this Mac's loopback.
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

    private(set) var store: TaskStore?
    private(set) var host: PairedHost?
    var pairingRoute: PairingRoute?
    var showingScanner = false

    let pairing: Pairing
    private var presetPrompt = ""

    init() {
        let keys = KeychainDeviceKeyStore()
        let hosts = FilePairedHostStore()
        var transport: BridgeTransportFactory = WebSocketTransport.factory
        #if DEBUG
        let options = DebugLaunchOptions.parse(ProcessInfo.processInfo.arguments)
        if options.resetPairing {
            try? hosts.removeAll()
            try? keys.reset()
        }
        if options.useFakeBridge { transport = FakeBridge.factory() }
        presetPrompt = options.presetPrompt ?? ""
        #endif
        pairing = Pairing(keys: keys, hosts: hosts, transport: transport)
        host = hosts.load().last
        store = makeStore()
    }

    /// The channel the current store uses, for the status row (`host.channel`).
    var channelName: String { store?.channelName ?? "none" }

    var hostLabel: String {
        if let host { return host.name.isEmpty ? host.addresses.first?.description ?? "host" : host.name }
        return "this Mac (dev, loopback)"
    }

    private func makeStore() -> TaskStore? {
        #if DEBUG
        let options = DebugLaunchOptions.parse(ProcessInfo.processInfo.arguments)
        if options.useFakeBridge {
            return TaskStore(connection: HostConnection(endpoint: .localBridge(), channel: PlaintextChannel(), transport: pairing.transport),
                             prompt: presetPrompt)
        }
        #endif
        if let host, let endpoint = host.addresses.first, let channel = try? pairing.reconnectChannel(to: host) {
            return TaskStore(connection: HostConnection(endpoint: endpoint, channel: channel, transport: pairing.transport),
                             prompt: presetPrompt)
        }
        #if DEBUG
        let endpoint = HostEndpoint.localBridge(port: options.bridgePort ?? 47801)
        return TaskStore(connection: HostConnection(endpoint: endpoint, channel: PlaintextChannel(), transport: pairing.transport),
                         prompt: presetPrompt)
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
            store = makeStore()
        }
        pairingRoute = nil
    }
}
