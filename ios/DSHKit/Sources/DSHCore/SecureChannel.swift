import Foundation

/// Where a bridge listens. T0 has one, hardcoded to loopback (see `HostEndpoint.localBridge`).
public struct HostEndpoint: Sendable, Equatable, CustomStringConvertible {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// The bridge on this Mac, as seen from the iOS Simulator. Port 47801 is this worktree's
    /// bridge port (PLAN.md T0); debug builds can override it with `-DSHMBridgePort`.
    public static func localBridge(port: Int = 47801) -> HostEndpoint {
        HostEndpoint(host: "127.0.0.1", port: port)
    }

    public var webSocketURL: URL {
        let h = host.contains(":") ? "[\(host)]" : host
        return URL(string: "ws://\(h):\(port)")!
    }

    public var description: String { "\(host):\(port)" }
}

public enum SecureChannelError: Error, Equatable, CustomStringConvertible {
    case nonLoopbackRefused(String)

    public var description: String {
        switch self {
        case .nonLoopbackRefused(let host):
            "PlaintextChannel refuses non-loopback address \(host)"
        }
    }
}

/// Transport security seam (ARCHITECTURE D6). Every frame passes through `seal` / `open`.
/// T0 has only `PlaintextChannel`; S1 adds a Noise channel behind this protocol.
public protocol SecureChannel: Sendable {
    var name: String { get }
    /// Throws if this channel may not be used to reach `endpoint`. Checked before any socket opens.
    func validate(_ endpoint: HostEndpoint) throws
    func seal(_ plaintext: Data) throws -> Data
    func open(_ ciphertext: Data) throws -> Data
}

/// No encryption, so it only talks to loopback literals (127.0.0.0/8, ::1). Host names, even
/// "localhost", are refused: they can resolve anywhere.
public struct PlaintextChannel: SecureChannel {
    public let name = "plaintext"

    public init() {}

    public func validate(_ endpoint: HostEndpoint) throws {
        guard Self.isLoopback(endpoint.host) else {
            throw SecureChannelError.nonLoopbackRefused(endpoint.host)
        }
    }

    public func seal(_ plaintext: Data) throws -> Data { plaintext }
    public func open(_ ciphertext: Data) throws -> Data { ciphertext }

    public static func isLoopback(_ host: String) -> Bool {
        var h = host
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        var v4 = in_addr()
        if inet_pton(AF_INET, h, &v4) == 1 {
            return UInt32(bigEndian: v4.s_addr) >> 24 == 127
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, h, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { $0.elementsEqual([UInt8](repeating: 0, count: 15) + [1]) }
        }
        return false
    }
}
