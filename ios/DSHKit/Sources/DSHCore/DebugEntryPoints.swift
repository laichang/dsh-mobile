#if DEBUG
import Foundation

/// Debug-only testability entry points (ARCHITECTURE D16). Compiled out of Release;
/// scripts/check-release-clean verifies none of these strings reach a Release binary.
public enum DebugLaunchOptions {
    /// `-DSHMFakeBridge YES`: use the in-process FakeBridge instead of the loopback bridge.
    /// `-DSHMFakeBridge offline` (S2): the FakeBridge host is unreachable.
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

    public struct Options: Equatable, Sendable {
        public var useFakeBridge = false
        public var presetPrompt: String?
        public var bridgePort: Int?
        public var fakeMilestones = false
        public var fakeBridgeOffline = false
        public var resetStore = false
        public var connectDelay: Double?

        public init(
            useFakeBridge: Bool = false, presetPrompt: String? = nil, bridgePort: Int? = nil,
            fakeMilestones: Bool = false,
            fakeBridgeOffline: Bool = false, resetStore: Bool = false, connectDelay: Double? = nil
        ) {
            self.useFakeBridge = useFakeBridge
            self.presetPrompt = presetPrompt
            self.bridgePort = bridgePort
            self.fakeMilestones = fakeMilestones
            self.fakeBridgeOffline = fakeBridgeOffline
            self.resetStore = resetStore
            self.connectDelay = connectDelay
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
            options.fakeBridgeOffline = v == "offline"
        }
        if let v = values[resetStoreKey] { options.resetStore = yes.contains(v) }
        options.connectDelay = values[connectDelayKey].flatMap(Double.init)
        options.presetPrompt = values[presetPromptKey]
        options.bridgePort = values[bridgePortKey].flatMap(Int.init)
        if let v = values[fakeMilestonesKey] { options.fakeMilestones = yes.contains(v) }
        return options
    }
}

/// Routes for the reserved `dshm://` scheme. S1 replaces the pairing stub with real pairing.
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
