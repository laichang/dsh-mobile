import Foundation

/// Where a bridge listens: one "host:port" from a pairing offer, or the Mac's loopback in Debug.
public struct HostEndpoint: Sendable, Equatable, Codable, CustomStringConvertible {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Parses "host:port", with IPv6 hosts in brackets ("[fd7a::1]:47801").
    public init?(address: String) {
        let hostPart: Substring, portPart: Substring
        if address.hasPrefix("[") {
            guard let close = address.firstIndex(of: "]"),
                  address[address.index(after: close)...].hasPrefix(":") else { return nil }
            hostPart = address[address.index(after: address.startIndex)..<close]
            portPart = address[address.index(close, offsetBy: 2)...]
        } else {
            let parts = address.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            hostPart = parts[0]
            portPart = parts[1]
        }
        guard !hostPart.isEmpty, let port = Int(portPart), (1...65535).contains(port) else { return nil }
        self.init(host: String(hostPart), port: port)
    }

    #if DEBUG
    /// The bridge on this Mac, as seen from the iOS Simulator (the plaintext dev path). Debug
    /// builds only; `-DSHMBridgePort` overrides the port.
    public static func localBridge(port: Int = 47801) -> HostEndpoint {
        HostEndpoint(host: "127.0.0.1", port: port)
    }
    #endif

    /// `ws://host:port<path>`; the channel picks the path (`SecureChannel.path`).
    public func webSocketURL(path: String = "/") -> URL {
        let h = host.contains(":") ? "[\(host)]" : host
        return URL(string: "ws://\(h):\(port)\(path)")!
    }

    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// Seals and opens the frames of one established connection, in order.
public protocol FrameCipher: Sendable {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ ciphertext: Data) throws -> Data
}

/// Transport security seam. `HostConnection` validates the endpoint, opens a
/// transport to `path`, lets the channel run its handshake, then passes every frame through the
/// returned `FrameCipher`. Release builds have only `NoiseChannel`; `PlaintextChannel` is
/// Debug-only and loopback-only.
public protocol SecureChannel: Sendable {
    var name: String { get }
    /// The WebSocket path on the bridge for this channel.
    var path: String { get }
    /// Throws if this channel may not be used to reach `endpoint`. Checked before any socket opens.
    func validate(_ endpoint: HostEndpoint) throws
    /// Runs the handshake (if any) over a freshly opened transport.
    func establish(over transport: any BridgeTransport) async throws -> any FrameCipher
}

#if DEBUG
public enum SecureChannelError: Error, Equatable, CustomStringConvertible {
    case nonLoopbackRefused(String)

    public var description: String {
        switch self {
        case .nonLoopbackRefused(let host):
            "PlaintextChannel refuses non-loopback address \(host)"
        }
    }
}

/// No encryption, so it only talks to loopback literals (127.0.0.0/8, ::1). Host names, even
/// "localhost", are refused: they can resolve anywhere. Debug builds only: it reaches the
/// bridge's dev-only `/plaintext` path (bridge `devPlaintext`), which the round-trip demo uses.
public struct PlaintextChannel: SecureChannel {
    public let name = "plaintext"
    public let path = "/plaintext"

    public init() {}

    public func validate(_ endpoint: HostEndpoint) throws {
        guard Self.isLoopback(endpoint.host) else {
            throw SecureChannelError.nonLoopbackRefused(endpoint.host)
        }
    }

    public func establish(over transport: any BridgeTransport) async throws -> any FrameCipher {
        Identity()
    }

    struct Identity: FrameCipher {
        func seal(_ plaintext: Data) throws -> Data { plaintext }
        func open(_ ciphertext: Data) throws -> Data { ciphertext }
    }

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
#endif
