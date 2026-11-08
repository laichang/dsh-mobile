import Foundation

/// Why one address of a host could not be used, the last time it was tried (D98).
public struct AddressFailure: Sendable, Equatable, CustomStringConvertible {
    public var endpoint: HostEndpoint
    /// A short reason (`AddressFailure.reason(for:)`), e.g. "URL error -1004, connection refused".
    public var reason: String

    public init(endpoint: HostEndpoint, reason: String) {
        self.endpoint = endpoint
        self.reason = reason
    }

    public init(endpoint: HostEndpoint, error: any Error) {
        self.init(endpoint: endpoint, reason: Self.reason(for: error))
    }

    /// "192.168.1.5:47801 (URL error -1001, timed out)".
    public var description: String { "\(endpoint.description) (\(reason))" }

    /// A short reason for a failed connection, for the failure detail. S31: the bare "couldn't
    /// reach" hid an App Transport Security refusal.
    public static func reason(for error: any Error) -> String {
        if let timeout = error as? AddressTimeout { return timeout.description }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return String(describing: error) }
        let name: String? = switch ns.code {
        case NSURLErrorAppTransportSecurityRequiresSecureConnection: "App Transport Security"
        case NSURLErrorCannotConnectToHost: "connection refused"
        case NSURLErrorTimedOut: "timed out"
        case NSURLErrorNotConnectedToInternet: "no network"
        case NSURLErrorNetworkConnectionLost: "connection lost"
        case NSURLErrorCannotFindHost: "host not found"
        default: nil
        }
        return name.map { "URL error \(ns.code), \($0)" } ?? "URL error \(ns.code)"
    }
}

/// One address gave no answer within `HostConnection.attemptTimeout` (D98).
public struct AddressTimeout: Error, Equatable, CustomStringConvertible {
    public var after: Duration

    public var description: String {
        let seconds = Double(after.components.seconds) + Double(after.components.attoseconds) / 1e18
        return "no answer in \(seconds.formatted(.number.precision(.fractionLength(0...1)))) s"
    }
}
