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
