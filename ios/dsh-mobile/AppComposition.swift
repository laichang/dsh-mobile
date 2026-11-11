import DSHCore
import DSHProtocol
import Foundation
import SwiftData
import UIKit
#if DEBUG
import DSHTestSupport
#endif

/// Each paired host syncs over its own pinned TLS connection into the shared task list.
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
    /// 08 opens the scanner to scan, or to paste a link.
    private(set) var scannerMode: ScannerView.Mode = .scan

    let pairing: Pairing
    /// The Live Activity of each running task (screen L). One for the app: each store uses it.
    let activityClient = ActivityKitClient()
    @ObservationIgnored private lazy var liveActivities = LiveActivities(client: activityClient) { row in
        MilestoneBar.line(row.milestones, state: row.state, alert: nil)
    }
    /// False for a Debug test launch that does not ask for Live Activities.
    @ObservationIgnored private var liveActivitiesOn = true
    /// The mic key's speech to text: the Speech framework, or in Debug `-DSHMFakeSpeech`.
    let transcriber: TranscriberFactory
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var presetPrompt = ""
    @ObservationIgnored private var connectDelay: Duration = .zero
    /// Hosts this device lost its access to (a revoke of this device), until they are
    /// paired again. A paired host also leaves the file; this set keeps a fake host
    /// out of the store, says each revoke once, and keeps the Debug loopback away from 08.
    @ObservationIgnored private var forgottenHostKeys: Set<String> = []
    /// The host that revoked this phone without a revoke from this phone's hosts sheet
    /// (another client, or the close came first). The root says so once.
    var revokedNotice: String?

    init() {
        let hosts = FilePairedHostStore()
        // After a timeout, a TCP connect tells another program on the port from no computer.
        var probe: PortProbe? = TCPPortProbe.probe
        var transcriber = SpeechFrameworkTranscriber.factory
        container = Self.makeContainer()
        #if DEBUG
        let options = DebugLaunchOptions.parse(ProcessInfo.processInfo.arguments)
        // XCUITest waits before each step until UIKit's view animations end; under load it
        // could wait 60 s per step for one whose end it did not see.
        if !options.uikitAnimations { UIView.setAnimationsEnabled(false) }
        // A test launch starts no Live Activities unless it asks, and ends the ones left.
        liveActivitiesOn = DebugLaunchOptions.liveActivitiesOn(ProcessInfo.processInfo.arguments)
        if options.resetPairing {
            for host in hosts.load() { try? Pairing.removeCredential(for: host) }
            try? hosts.removeAll()
        }
        if ProcessInfo.processInfo.arguments.contains("-DSHMSeedLegacyPairing") {
            try! LegacyPairingFixture.install(in: hosts)
        }
        if options.resetStore {
            try? TaskCache.erase(container)
            UserDefaults.standard.removeObject(forKey: Self.preferredHostKey)
        }
        if options.useFakeBridge { probe = nil }
        presetPrompt = options.presetPrompt ?? ""
        if let seconds = options.connectDelay { connectDelay = .milliseconds(Int(seconds * 1000)) }
        if let speech = options.fakeSpeech { transcriber = FakeTranscriber.factory(speech) }
        #endif
        self.transcriber = transcriber
        pairing = Pairing(hosts: hosts, probe: probe)
        if !liveActivitiesOn { activityClient.dismissAll() }
        store = makeStore()
    }

    private func makeStore() -> TaskListStore? {
        let hosts = hostConfigs().filter { !forgottenHostKeys.contains($0.key) }
        guard !hosts.isEmpty else { return nil }
        let store = TaskListStore(container: container, hosts: hosts, prompt: presetPrompt, firstConnectDelay: connectDelay,
                                  preferredHostKey: UserDefaults.standard.string(forKey: Self.preferredHostKey)) { key in
            UserDefaults.standard.set(key, forKey: Self.preferredHostKey)
        }
        store.onHostRevoked = { [weak self] host in self?.hostRevoked(host) }
        if liveActivitiesOn { store.liveActivities = liveActivities }
        return store
    }

    /// A host refused this device with close 4003, so it was revoked. Forget it as
    /// after a revoke from the hosts sheet, and say so once.
    private func hostRevoked(_ host: TaskListStore.HostStatus) {
        guard !forgottenHostKeys.contains(host.key) else { return }
        revokedNotice = host.name
        forgetHost(host.key)
    }

    func retrySavedHosts() {
        store = makeStore()
        store?.foreground()
    }

    private func pairedConfig(_ host: PairedHost) -> TaskListStore.HostConfig? {
        // Every saved address, the one that worked last first; a new working one is saved first.
        guard let endpoint = host.addresses.first, let connection = try? pairing.connection(to: host) else { return nil }
        return .init(key: host.cacheKey, connection: connection, name: host.name.isEmpty ? endpoint.description : host.name)
    }

    private func hostConfigs() -> [TaskListStore.HostConfig] {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let encoded = environment["DSHM_TLS_TEST_PIN"], let pin = Data(base64Encoded: encoded),
           let addresses = environment["DSHM_TLS_TEST_ADDRESSES"] {
            let endpoints = addresses.split(separator: ",").compactMap { HostEndpoint(address: String($0)) }
            if !endpoints.isEmpty {
                hasSavedHosts = true
                return [.init(key: "tls:\(encoded)", connection: .init(endpoints: endpoints, spkiSHA256: pin), name: "TLS host")]
            }
        }
        let options = DebugLaunchOptions.parse(ProcessInfo.processInfo.arguments)
        if let drawer = options.fakeDrawer.flatMap(FakeDrawer.Variant.init(rawValue:)) { return FakeDrawer.hosts(drawer) }
        if options.fakePickers { return FakePickers.hosts(hold: options.fakeHold) }
        if let variant = options.fakeHosts.flatMap(FakeHosts.Variant.init(rawValue:)) { return fakeHosts(variant) }
        if options.multipleFakeHosts {
            return ["Office Mac", "Home Mac"].enumerated().map { index, name in
                let endpoint = HostEndpoint.localBridge(port: 47801 + index)
                var script = FakeBridge.Script(reply: ["Reply ", "from ", name], chunkDelay: .seconds(1))
                script.holdPrompt = options.fakeHold
                script.ask = options.fakeAsk.map { ($0, FakeApprovalSheet.asked) }
                let fake = FakeHost(script: script,
                                    hostName: name, reachable: index != 0 || !options.fakeBridgeOffline,
                                    extraCapabilities: options.fakeScenario == "attachments" ? [DSHProtocolInfo.attachmentsCapability] : [],
                                    approvals: options.fakeApprovals ? FakeApprovals.seed(for: name) : [])
                if options.fakeApprovals { FakeApprovalSheet.watchWebAnswers(fake) }
                return .init(key: "fake:\(name)", connection: HostConnection(endpoint: endpoint,
                             transport: fake.factory), name: name)
            }
        }
        if options.useFakeBridge {
            let endpoint = HostEndpoint.localBridge()
            var script: FakeBridge.Script = options.fakeMilestones ? .threeTodos() : .init()
            if options.fakeScenario == "coding" { script = .codingTask() }
            if options.fakeScenario == "outcomes" { script = .outcomes() }
            if options.fakeScenario?.hasPrefix("transcript") == true { script = FakeTranscript.script() }
            if options.fakeScenario == "live-activity" { script = .threeTodos(delay: .seconds(5)) } // Time to lock the screen
            if options.fakeScenario == "conversation" { script.followUpReply = ["Got it", ", ", "on it", "."] }
            script.holdPrompt = options.fakeHold ?? script.holdPrompt
            let fake = options.fakeScenario == "turns" ? FakeTurns.host()
                : FakeHost(script: script, reachable: !options.fakeBridgeOffline,
                           extraCapabilities: options.fakeScenario == "transcript" ? [FakeTranscript.capability] : [])
            if options.fakeScenario == "outcomes" { FakeApprovalSheet.watchWebAnswers(fake) }
            return [.init(key: "fake:\(endpoint)",
                          connection: HostConnection(endpoint: endpoint, transport: fake.factory))]
        }
        #endif
        let paired = pairing.hosts.load()
        hasSavedHosts = !paired.isEmpty
        return paired.compactMap(pairedConfig)
    }

    /// This device lost its access to the host (it revoked itself): forget the pairing
    /// and rebuild the store without it. With no host left, the root shows 08 (`WelcomeView`).
    func forgetHost(_ key: String) {
        // Once per host; the revoke response and the close 4003 can both report it.
        guard forgottenHostKeys.insert(key).inserted else { return }
        if let host = pairing.hosts.load().first(where: { $0.cacheKey == key }) {
            try? Pairing.removeCredential(for: host)
            try? pairing.hosts.remove(id: host.id)
        }
        store?.background()
        store = makeStore()
        store?.foreground()
    }

    #if DEBUG
    private func fakeHosts(_ variant: FakeHosts.Variant) -> [TaskListStore.HostConfig] {
        let (configs, switchable) = FakeHosts.hosts(variant)
        FakeHostsSwitch.watch(switchable) { Task { @MainActor [weak self] in self?.store?.foreground() } }
        return configs
    }
    #endif

    func startPairing(_ mode: ScannerView.Mode = .scan) {
        scannerMode = mode
        showingScanner = true
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
            // The same Mac paired again after a revoke has the same key (the id comes
            // from the host key). It is a new pairing: keep it, and let a later revoke forget it again.
            forgottenHostKeys.remove(paired.cacheKey)
            if let store, store.hosts.contains(where: { $0.isEncrypted }), let config = pairedConfig(paired) {
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
    /// start from an empty one rather than not at all. The host is the source of truth.
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
