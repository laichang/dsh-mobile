import DSHTransport
import Foundation

/// The pairing offer a bridge shows as a QR code, parsed from its
/// `dshm://pair?…` URL. The same URL is the Debug-only deep link, so the Simulator can pair
/// without a camera. Written by bridge/src/pairing/offer.ts:
///
///     dshm://pair?v=2&n=<host name>&a=<host:port>,<host:port>&k=<host key>&i=<offer id>&s=<secret>&x=<expiry>
///
/// k, i and s are unpadded base64url (32, 16 and 32 bytes); x is Unix seconds.
public struct PairingOffer: Sendable, Equatable {
    public var hostName: String
    /// Tried in order.
    public var addressDescriptions: [String] { addresses.map(\.description) }
    package var addresses: [HostEndpoint]
    public var hostKey: [UInt8]
    public var offerID: [UInt8]
    public var secret: [UInt8]
    public var expiresAt: Date

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notAPairingLink
        case unsupportedVersion(String)
        case badField(String)

        public var description: String {
            switch self {
            case .notAPairingLink: "not a dsh-mobile pairing code"
            case .unsupportedVersion(let v): "unsupported pairing code version \(v). Generate a new pairing code on the updated host."
            case .badField(let f): "pairing code field \(f) is missing or malformed"
            }
        }
    }

    public init(hostName: String, addresses: [HostEndpoint], hostKey: [UInt8], offerID: [UInt8], secret: [UInt8], expiresAt: Date) {
        self.hostName = hostName
        self.addresses = addresses
        self.hostKey = hostKey
        self.offerID = offerID
        self.secret = secret
        self.expiresAt = expiresAt
    }

    public init(url: URL) throws(ParseError) {
        guard url.scheme == "dshm", url.host() == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw .notAPairingLink }
        var q: [String: String] = [:]
        // The bridge writes the query with URLSearchParams (form encoding: space is "+").
        func decode(_ s: String) -> String { s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s }
        for item in components.percentEncodedQueryItems ?? [] { q[decode(item.name)] = decode(item.value ?? "") }
        guard q["v"] == "2" else { throw .unsupportedVersion(q["v"] ?? "none") }
        func bytes(_ key: String, _ length: Int) throws(ParseError) -> [UInt8] {
            guard let s = q[key], let b = Self.base64URLDecode(s), b.count == length else { throw .badField(key) }
            return b
        }
        let parts = (q["a"] ?? "").split(separator: ",", omittingEmptySubsequences: false)
        let addresses = parts.compactMap { HostEndpoint(address: String($0)) }
        guard !addresses.isEmpty, addresses.count == parts.count else { throw .badField("a") }
        guard addresses.allSatisfy({ endpoint in
            guard let url = URL(string: "https://" + endpoint.description, encodingInvalidCharacters: false) else { return false }
            return url.host(percentEncoded: false)?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == endpoint.host && url.port == endpoint.port
                && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil && url.path.isEmpty
        }) else { throw .badField("a") }
        guard let x = q["x"].flatMap(TimeInterval.init), x.isFinite, x > 0 else { throw .badField("x") }
        self.init(
            hostName: q["n"] ?? "",
            addresses: addresses,
            hostKey: try bytes("k", 32),
            offerID: try bytes("i", 16),
            secret: try bytes("s", 32),
            expiresAt: Date(timeIntervalSince1970: x))
    }

    public init(string: String) throws(ParseError) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw .notAPairingLink }
        try self.init(url: url)
    }

    public func isExpired(at now: Date = .now) -> Bool { now >= expiresAt }

    static func base64URLDecode(_ s: String) -> [UInt8]? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b).map(Array.init)
    }
}
