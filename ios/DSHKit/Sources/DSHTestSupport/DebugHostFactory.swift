#if DEBUG
import DSHCore
import DSHFeatures
import DSHProtocol
import DSHTransport
import Foundation

public enum DebugHostFactory {
    public static func pairing() -> Pairing {
        Pairing(hosts: FilePairedHostStore(), probe: nil)
    }

    @MainActor
    public static func hosts(options: DebugLaunchOptions.Options, environment: [String: String],
                             wake: @escaping @Sendable () -> Void) -> [HostSync.HostConfig]? {
        if let encoded = environment["DSHM_TLS_TEST_PIN"], let pin = Data(base64Encoded: encoded),
           let addresses = environment["DSHM_TLS_TEST_ADDRESSES"] {
            let endpoints = addresses.split(separator: ",").compactMap { HostEndpoint(address: String($0)) }
            if !endpoints.isEmpty {
                return [.init(key: "tls:\(encoded)", connection: .init(endpoints: endpoints, spkiSHA256: pin), name: "TLS host")]
            }
        }
        if let drawer = options.fakeDrawer.flatMap(FakeDrawer.Variant.init(rawValue:)) { return FakeDrawer.hosts(drawer) }
        if options.fakePickers { return FakePickers.hosts(hold: options.fakeHold) }
        if let variant = options.fakeHosts.flatMap(FakeHosts.Variant.init(rawValue:)) {
            let (configs, switchable) = FakeHosts.hosts(variant)
            FakeHostsSwitch.watch(switchable, wake: wake)
            return configs
        }
        if let scenario = options.fakeScenario.flatMap(DurableHostScenario.init(rawValue:)) { return scenario.hosts() }
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
        return nil
    }
}
#endif
