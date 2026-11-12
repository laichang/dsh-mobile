import DSHTransport
import Foundation
import Observation

public enum PairingError: Error, Equatable, CustomStringConvertible {
    case expired
    /// Each address tried, with why it failed (`reason(for:)`), e.g. `100.79.171.34:47801
    /// (URL error -1022, App Transport Security)`. The bare "couldn't reach" hid an ATS refusal.
    case unreachable([String])

    public var description: String {
        switch self {
        case .expired: "this pairing code has expired; show a new one on the host"
        case .unreachable(let tried): "couldn't reach the host at \(tried.joined(separator: ", "))"
        }
    }

    /// A short reason for a failed connection, for the failure detail (`AddressFailure.reason(for:)`).
    public static func reason(for error: any Error) -> String { AddressFailure.reason(for: error) }
}

public struct Pairing: Sendable {
    public let hosts: any PairedHostStore
    /// The TCP probe after an address gave no answer (`TCPPortProbe.probe` in the app);
    /// nil in tests and with Debug's fake bridge, whose addresses are not real.
    package let probe: PortProbe?
    public let now: @Sendable () -> Date

    public init(hosts: any PairedHostStore = FilePairedHostStore()) {
        self.init(hosts: hosts, probe: TCPPortProbe.probe)
    }

    package init(hosts: any PairedHostStore,
                probe: PortProbe?, now: @escaping @Sendable () -> Date = { .now }) {
        self.hosts = hosts
        self.probe = probe
        self.now = now
    }

    public func pair(_ offer: PairingOffer) async throws -> PairedHost {
        // The bridge enforces expiry too; refusing early keeps a stale QR off the network.
        guard !offer.isExpired(at: now()) else { throw PairingError.expired }
        return try await enroll(offer)
    }

    public func forget(cacheKey: String) throws {
        try forget(cacheKey: cacheKey, deletingCredential: Self.removeCredential)
    }

    func forget(cacheKey: String, deletingCredential: (PairedHost) throws -> Void) throws {
        for host in try hosts.retire(cacheKey: cacheKey) {
            try deletingCredential(host)
            try hosts.acknowledgeRemoval(of: host)
        }
    }

    package func connection(to host: PairedHost, attemptTimeout: Duration = HostConnection.defaultAttemptTimeout) throws -> HostConnection {
        let store = hosts
        let saveAddresses: @Sendable ([HostEndpoint]) -> Void = { addresses in
            var saved = host
            saved.addresses = addresses
            try? store.update(saved)
        }
        guard let deviceID = host.tlsDeviceID else { throw PairingError.unreachable(["Scan a new pairing code from the host."]) }
        let pin = Data(host.hostKey), key = Self.credential(pin: host.hostKey, deviceID: deviceID)
        return HostConnection(endpoints: host.addresses, channelName: "TLS 1.3", transport: { url in
            guard let data = try key.read(), let bearer = String(data: data, encoding: .utf8) else {
                throw PairingError.unreachable(["device credential unavailable"])
            }
            var check = URLRequest(url: url.withScheme("https").appending(path: "device"))
            check.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
            let (_, status) = try await WebSocketTransport.pinnedRequest(check, spkiSHA256: pin)
            if status.statusCode == 403 && status.value(forHTTPHeaderField: "x-dshm-device") == "unknown" {
                throw HostConnectionError.deviceRevoked
            }
            guard status.statusCode == 204 else { throw URLError(.badServerResponse) }
            return try WebSocketTransport.pinnedTLS(url: url, spkiSHA256: pin, authorization: "Bearer " + bearer)
        }, attemptTimeout: attemptTimeout, probe: probe, onAddressesChange: saveAddresses)
    }
}

/// State behind the pairing screen: review the offer, pair, report.
@MainActor
@Observable
public final class PairingModel {
    public enum State: Equatable, Sendable {
        case reviewing
        case pairing
        case paired(PairedHost)
        case failed(String)

        /// Stable token for UI tests (`pairing.status` accessibility value).
        public var token: String {
            switch self {
            case .reviewing: "reviewing"
            case .pairing: "pairing"
            case .paired: "paired"
            case .failed: "failed"
            }
        }
    }

    public nonisolated let offer: PairingOffer
    public private(set) var state: State = .reviewing
    private let pairing: Pairing

    public init(offer: PairingOffer, pairing: Pairing) {
        self.offer = offer
        self.pairing = pairing
    }

    public func pair() async {
        guard state == .reviewing || state.token == "failed" else { return }
        state = .pairing
        do {
            state = .paired(try await pairing.pair(offer))
        } catch {
            state = .failed(String(describing: error))
        }
    }
}
