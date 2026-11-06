#if DEBUG
import Foundation

/// Debug-only testability entry points (ARCHITECTURE D16). Compiled out of Release;
/// scripts/check-release-clean verifies none of these strings reach a Release binary.
public enum DebugLaunchOptions {
    /// `-DSHMFakeBridge YES`: use the in-process FakeBridge instead of the loopback bridge.
    /// `-DSHMFakeBridge offline` (S2): the FakeBridge host is unreachable.
    /// `-DSHMFakeBridge drawer`, `drawer-office-offline`, `drawer-v0` (S14): two hosts with
    /// sessions in workspaces (`FakeDrawer`).
    /// `-DSHMFakeBridge approvals` (S15): two hosts, each with a task that waits on an approval;
    /// `approvals-office-offline`: the same, with Office Mac unreachable.
    /// `-DSHMFakeBridge hosts`, `hosts-one` (S21): the hosts of screens H, X2 and X3 (`FakeHosts`).
    public static let fakeBridgeKey = "DSHMFakeBridge"
    /// `-DSHMPresetPrompt <text>`: pre-fill the composer.
    public static let presetPromptKey = "DSHMPresetPrompt"
    /// `-DSHMBridgePort <port>`: loopback bridge port (default 47801).
    public static let bridgePortKey = "DSHMBridgePort"
    /// `-DSHMFakeMilestones YES`: with the FakeBridge, script a three-todo task (S3).
    public static let fakeMilestonesKey = "DSHMFakeMilestones"
    /// `-DSHMResetStore YES` (S2): start with an empty task cache.
    public static let resetStoreKey = "DSHMResetStore"
    /// `-DSHMConnectDelay <seconds>` (S2): show the cache for a while before the first connection.
    public static let connectDelayKey = "DSHMConnectDelay"
    /// `-DSHMResetPairing YES`: forget paired hosts and the device key at launch (S1 UI tests).
    public static let resetPairingKey = "DSHMResetPairing"
    /// `-DSHMFakeHold <text>` (T1): with the FakeBridge, a task whose prompt contains `<text>`
    /// stays running until the app quits, so a UI test can act on a running task.
    public static let fakeHoldKey = "DSHMFakeHold"
    /// `-DSHMFakeAsk <text>` (S18): with the FakeBridge approvals scenario, a task whose prompt
    /// contains `<text>` asks for an approval before its reply, so a new approval arrives in an
    /// open session.
    public static let fakeAskKey = "DSHMFakeAsk"

    public struct Options: Equatable, Sendable {
        public var useFakeBridge = false
        public var presetPrompt: String?
        public var bridgePort: Int?
        public var fakeMilestones = false
        public var multipleFakeHosts = false
        public var fakeBridgeOffline = false
        public var resetStore = false
        public var connectDelay: Double?
        public var resetPairing = false
        public var fakeHold: String?
        /// S14: the `FakeDrawer` variant (`drawer`, `drawer-office-offline`, `drawer-v0`).
        public var fakeDrawer: String?
        public var fakeApprovals = false
        public var fakeAsk: String?
        /// S21: the `FakeHosts` variant (`hosts`, `hosts-one`).
        public var fakeHosts: String?

        public init(
            useFakeBridge: Bool = false, presetPrompt: String? = nil, bridgePort: Int? = nil,
            fakeMilestones: Bool = false,
            fakeBridgeOffline: Bool = false, resetStore: Bool = false, connectDelay: Double? = nil,
            resetPairing: Bool = false, fakeHold: String? = nil
        ) {
            self.useFakeBridge = useFakeBridge
            self.presetPrompt = presetPrompt
            self.bridgePort = bridgePort
            self.fakeMilestones = fakeMilestones
            self.fakeBridgeOffline = fakeBridgeOffline
            self.resetStore = resetStore
            self.connectDelay = connectDelay
            self.resetPairing = resetPairing
            self.fakeHold = fakeHold
        }
    }

    /// Parses `-Key value` pairs, the same form XCUITest's `launchArguments` and Xcode use.
    public static func parse(_ arguments: [String]) -> Options {
        var values: [String: String] = [:]
        var i = arguments.startIndex
        while i < arguments.endIndex {
            let arg = arguments[i]
            if arg.hasPrefix("-"), arguments.index(after: i) < arguments.endIndex {
                values[String(arg.dropFirst())] = arguments[arguments.index(after: i)]
                i = arguments.index(i, offsetBy: 2)
            } else {
                i = arguments.index(after: i)
            }
        }
        var options = Options()
        let yes = ["YES", "1", "true"]
        if let v = values[fakeBridgeKey] {
            options.useFakeBridge = yes.contains(v) || v == "offline"
            options.fakeApprovals = v == "approvals" || v == "approvals-office-offline"
            options.multipleFakeHosts = v == "multi" || v == "multi-office-offline" || options.fakeApprovals
            options.fakeBridgeOffline = v == "offline" || v == "multi-office-offline" || v == "approvals-office-offline"
            if v.hasPrefix("drawer") { options.fakeDrawer = v }
            if v.hasPrefix("hosts") { options.fakeHosts = v }
        }
        if let v = values[resetStoreKey] { options.resetStore = yes.contains(v) }
        options.connectDelay = values[connectDelayKey].flatMap(Double.init)
        options.presetPrompt = values[presetPromptKey]
        options.bridgePort = values[bridgePortKey].flatMap(Int.init)
        if let v = values[fakeMilestonesKey] { options.fakeMilestones = yes.contains(v) }
        if let v = values[resetPairingKey] { options.resetPairing = yes.contains(v) }
        options.fakeHold = values[fakeHoldKey]
        options.fakeAsk = values[fakeAskKey]
        return options
    }
}

/// Routes for the reserved `dshm://` scheme, which only Debug builds register. `dshm://pair?…`
/// carries a `PairingOffer` (S1); Release builds get the same offer from the QR scanner.
public enum DebugDeepLink: Equatable, Sendable {
    case pair(parameters: [String: String])

    public static func route(_ url: URL) -> DebugDeepLink? {
        guard url.scheme == "dshm", url.host() == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] { parameters[item.name] = item.value ?? "" }
        return .pair(parameters: parameters)
    }
}
#endif
