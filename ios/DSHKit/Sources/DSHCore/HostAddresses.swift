import DSHTransport
import Foundation

/// Why one address of a host could not be used, the last time it was tried.
public struct AddressFailure: Sendable, Equatable, CustomStringConvertible {
    package var endpoint: HostEndpoint
    public var address: String { endpoint.description }
    public var port: Int { endpoint.port }
    /// A short reason (`AddressFailure.reason(for:)`), e.g. "URL error -1004, connection refused".
    public var reason: String
    /// What the failure says about the bridge's port, when that is clear; nil for other
    /// failures (App Transport Security, no network, the bridge's own refusals, ...).
    public var kind: Kind?

    /// The three reasons a bridge does not answer at an address.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// The computer answered and refused the connection: nothing listens on the port. DSH, or
        /// its bridge, is not running.
        case nothingListens
        /// Something takes connections on the port, but it is not a DSH bridge: an HTTP answer with
        /// no WebSocket upgrade, a close or a reply that no bridge sends, or a TCP connection that
        /// never answers. The bridge could not listen there.
        case otherProgram
        /// No answer at all: the computer is off or asleep, or not on this network.
        case notReachable
    }

    public init(endpoint: HostEndpoint, reason: String, kind: Kind? = nil) {
        self.endpoint = endpoint
        self.reason = reason
        self.kind = kind
    }

    public init(endpoint: HostEndpoint, error: any Error) {
        self.init(endpoint: endpoint, reason: Self.reason(for: error), kind: Self.kind(for: error))
    }

    /// "192.168.1.5:47801 (URL error -1001, timed out)".
    public var description: String { "\(endpoint.description) (\(reason))" }

    /// A short reason for a failed connection, for the failure detail. The bare "couldn't
    /// reach" hid an App Transport Security refusal.
    public static func reason(for error: any Error) -> String {
        if let timeout = error as? AddressTimeout { return timeout.description }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return String(describing: error) }
        let name: String? = switch ns.code {
        case NSURLErrorAppTransportSecurityRequiresSecureConnection: "App Transport Security"
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorUserCancelledAuthentication:
            "host identity could not be verified. Check the host and scan a new pairing code"
        case NSURLErrorCannotConnectToHost: "connection refused"
        case NSURLErrorTimedOut: "timed out"
        case NSURLErrorNotConnectedToInternet: "no network"
        case NSURLErrorNetworkConnectionLost: "connection lost"
        case NSURLErrorCannotFindHost: "host not found"
        case NSURLErrorBadServerResponse: "bad server response"
        default: nil
        }
        return name.map { "URL error \(ns.code), \($0)" } ?? "URL error \(ns.code)"
    }

    /// Which of the three reasons a failed try shows, if any.
    /// - Refused (`NSURLErrorCannotConnectToHost`): nothing listens.
    /// - An HTTP answer without the upgrade (`NSURLErrorBadServerResponse`), a connection that the
    ///   peer drops during the handshake (`NSURLErrorNetworkConnectionLost`), or a WebSocket peer
    ///   that is no bridge (a text message): another program.
    /// - No answer in time: the TCP probe decides (`AddressTimeout.port`); with no probe, not reachable.
    public static func kind(for error: any Error) -> Kind? {
        switch error {
        case let timeout as AddressTimeout:
            return switch timeout.port {
            case .accepted?: .otherProgram
            case .refused?: .nothingListens
            case .noAnswer?, nil: .notReachable
            }
        case BridgeTransportError.unexpectedTextMessage:
            return .otherProgram
        default:
            break
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return nil }
        return switch ns.code {
        case NSURLErrorCannotConnectToHost: .nothingListens
        case NSURLErrorBadServerResponse, NSURLErrorNetworkConnectionLost, NSURLErrorSecureConnectionFailed: .otherProgram
        case NSURLErrorTimedOut: .notReachable
        default: nil
        }
    }

    /// The failure that says most about a host whose every address failed, for the host row (H)
    /// and the offline card (X3): another program on the port first (the user must act on the
    /// computer), then nothing listening (DSH is not running), then not reachable. Nil when no
    /// failure has a kind.
    public static func mostTelling(_ failures: [AddressFailure]) -> AddressFailure? {
        let order: [Kind] = [.otherProgram, .nothingListens, .notReachable]
        return order.lazy.compactMap { kind in failures.first { $0.kind == kind } }.first
    }
}

/// One address gave no answer within `HostConnection.attemptTimeout`.
public struct AddressTimeout: Error, Equatable, CustomStringConvertible {
    public var after: Duration
    /// What a plain TCP connect to the address found after the timeout; nil when not probed.
    public var port: PortProbeResult?

    public init(after: Duration, port: PortProbeResult? = nil) {
        self.after = after
        self.port = port
    }

    public var description: String {
        let seconds = Double(after.components.seconds) + Double(after.components.attoseconds) / 1e18
        let base = "no answer in \(seconds.formatted(.number.precision(.fractionLength(0...1)))) s"
        return switch port {
        case .accepted?: "\(base); the port takes connections"
        case .refused?: "\(base); the port refuses connections"
        case .noAnswer?, nil: base
        }
    }
}
