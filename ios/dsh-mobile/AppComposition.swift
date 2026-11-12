import DSHCore
import DSHFeatures
import Foundation
import UIKit
#if DEBUG
import DSHTestSupport
#endif

/// Each paired host syncs over its own TLS connection into the shared task list.
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
    @ObservationIgnored private let cache: TaskCache
    @ObservationIgnored private var presetPrompt = ""
    @ObservationIgnored private var connectDelay: Duration = .zero
    /// In-process hosts also need to stay forgotten when the store is reconstructed.
    @ObservationIgnored private var forgotten = ForgottenEnrollments()
    /// The host that revoked this phone without a revoke from this phone's hosts sheet
    /// (another client, or the close came first). The root says so once.
    var revokedNotice: TaskListStore.HostStatus?
    var pairingRemovalError: String?

    init() {
        var pairing = Pairing()
        var transcriber = SpeechFrameworkTranscriber.factory
        cache = TaskCache.onDevice()
        #if DEBUG
        let options = DebugLaunchOptions.parse(ProcessInfo.processInfo.arguments)
        // XCUITest waits before each step until UIKit's view animations end; under load it
        // could wait 60 s per step for one whose end it did not see.
        if !options.uikitAnimations { UIView.setAnimationsEnabled(false) }
        // A test launch starts no Live Activities unless it asks, and ends the ones left.
        liveActivitiesOn = DebugLaunchOptions.liveActivitiesOn(ProcessInfo.processInfo.arguments)
        if options.resetPairing {
            for origin in pairing.hosts.load().compactMap(\.enrollment) { try? pairing.forget(origin) }
            try? pairing.hosts.removeAll()
        }
        if ProcessInfo.processInfo.arguments.contains("-DSHMSeedLegacyPairing") {
            try! LegacyPairingFixture.install(in: pairing.hosts)
        }
        if options.resetStore {
            try? cache.erase()
            UserDefaults.standard.removeObject(forKey: Self.preferredHostKey)
        }
        if options.useFakeBridge { pairing = DebugHostFactory.pairing() }
        presetPrompt = options.presetPrompt ?? ""
        if let seconds = options.connectDelay { connectDelay = .milliseconds(Int(seconds * 1000)) }
        if let speech = options.fakeSpeech { transcriber = FakeTranscriber.factory(speech) }
        #endif
        self.transcriber = transcriber
        self.pairing = pairing
        if !liveActivitiesOn { activityClient.dismissAll() }
        do { try pairing.retryPendingRemovals() } catch { pairingRemovalError = error.localizedDescription }
        store = makeStore()
    }

    private func makeStore() -> TaskListStore? {
        let hosts = hostConfigs().filter { !forgotten.enrollments.contains($0.enrollment) }
        guard !hosts.isEmpty else { return nil }
        let store = TaskListStore(cache: cache, hosts: hosts, prompt: presetPrompt, firstConnectDelay: connectDelay,
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
        if forgetHost(host.enrollment) { revokedNotice = host }
    }

    func retrySavedHosts() {
        store = makeStore()
        store?.foreground()
    }

    private func pairedConfig(_ host: PairedHost) -> TaskListStore.HostConfig? {
        .init(paired: host, using: pairing)
    }

    private func hostConfigs() -> [TaskListStore.HostConfig] {
        #if DEBUG
        let options = DebugLaunchOptions.parse(ProcessInfo.processInfo.arguments)
        if let configs = DebugHostFactory.hosts(options: options, environment: ProcessInfo.processInfo.environment,
                                                wake: { Task { @MainActor [weak self] in self?.store?.foreground() } }) {
            if ProcessInfo.processInfo.environment["DSHM_TLS_TEST_PIN"] != nil { hasSavedHosts = true }
            return configs
        }
        #endif
        let paired = pairing.hosts.load()
        hasSavedHosts = !paired.isEmpty
        return paired.compactMap(pairedConfig)
    }

    /// This device lost its access to the host (it revoked itself): forget the pairing
    /// and retire its connection. With no host left, the root shows 08 (`WelcomeView`).
    @discardableResult
    func forgetHost(_ origin: HostEnrollment) -> Bool {
        let removed: Bool
        do {
            // Debug's in-process hosts do not have a stored pairing or credential.
            removed = try forgotten.forget(origin) { [pairing] in
                $0.hostKey.isEmpty ? true : try pairing.forget($0)
            }
        } catch {
            pairingRemovalError = error.localizedDescription
            return false
        }
        guard removed else { return false }
        if !origin.hostKey.isEmpty,
           store?.hosts.contains(where: { $0.enrollment.hostKey == origin.hostKey && $0.enrollment != origin }) == true {
            return false
        }
        store?.forget(origin)
        if store?.hosts.isEmpty == true { store = nil }
        hasSavedHosts = !pairing.hosts.load().isEmpty
        return true
    }

    func startPairing(_ mode: ScannerView.Mode = .scan) {
        scannerMode = mode
        showingScanner = true
    }

    static let legacyPairingGuide = String(localized: "If the link contains v=1, it came from an older version. On the computer running DSH:\n\n1. Open another terminal in the updated dsh-mobile folder and run pnpm --dir bridge build.\n2. In the terminal running DSH, press Ctrl+C and run your usual startup command again (for example, dsh web).\n3. Back in the dsh-mobile folder, run node bridge/lib/scripts/pair.js and scan the new code.")

    /// A scanned QR payload, a pasted link, or (Debug) a `dshm://pair?…` deep link.
    func openPairingCode(_ text: String) {
        showingScanner = false
        do {
            pairingRoute = .offer(PairingModel(offer: try PairingOffer(string: text), pairing: pairing))
        } catch .unsupportedVersion("1") {
            pairingRoute = .invalid(Self.legacyPairingGuide)
        } catch {
            pairingRoute = .invalid(error.description)
        }
    }

    func closePairing() {
        if case .offer(let model)? = pairingRoute, case .paired(let paired) = model.state {
            if revokedNotice?.enrollment.hostKey == paired.hostKey { revokedNotice = nil }
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
}
