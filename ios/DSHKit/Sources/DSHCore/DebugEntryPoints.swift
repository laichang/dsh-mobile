#if DEBUG
import Foundation

/// Debug-only testability entry points (ARCHITECTURE D16). Compiled out of Release;
/// scripts/check-release-clean verifies none of these strings reach a Release binary.
public enum DebugLaunchOptions {
    /// `-DSHMFakeBridge YES`: use the in-process FakeBridge instead of the loopback bridge.
    public static let fakeBridgeKey = "DSHMFakeBridge"
    /// `-DSHMPresetPrompt <text>`: pre-fill the composer.
    public static let presetPromptKey = "DSHMPresetPrompt"
    /// `-DSHMBridgePort <port>`: loopback bridge port (default 47801).
    public static let bridgePortKey = "DSHMBridgePort"
    /// `-DSHMResetPairing YES`: forget paired hosts and the device key at launch (S1 UI tests).
    public static let resetPairingKey = "DSHMResetPairing"

    public struct Options: Equatable, Sendable {
        public var useFakeBridge = false
        public var presetPrompt: String?
        public var bridgePort: Int?
        public var resetPairing = false

        public init(useFakeBridge: Bool = false, presetPrompt: String? = nil, bridgePort: Int? = nil, resetPairing: Bool = false) {
            self.useFakeBridge = useFakeBridge
            self.presetPrompt = presetPrompt
            self.bridgePort = bridgePort
            self.resetPairing = resetPairing
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
        if let v = values[fakeBridgeKey] { options.useFakeBridge = ["YES", "1", "true"].contains(v) }
        options.presetPrompt = values[presetPromptKey]
        options.bridgePort = values[bridgePortKey].flatMap(Int.init)
        if let v = values[resetPairingKey] { options.resetPairing = ["YES", "1", "true"].contains(v) }
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
