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

/// Pairs with the host behind a QR offer: tries each address in order, runs the
/// `IKpsk1` handshake and Hello, then saves the host. Later connections use `IK`
/// (`NoiseChannel` `.reconnect`) with the saved host key.
public struct Pairing: Sendable {
    public let keys: any DeviceKeyStore
    public let hosts: any PairedHostStore
    package let transport: BridgeTransportFactory
    /// The TCP probe after an address gave no answer (`TCPPortProbe.probe` in the app);
    /// nil in tests and with Debug's fake bridge, whose addresses are not real.
    package let probe: PortProbe?
    public let now: @Sendable () -> Date

    public init(hosts: any PairedHostStore = FilePairedHostStore()) {
        self.init(keys: KeychainDeviceKeyStore(), hosts: hosts, transport: WebSocketTransport.factory,
                  probe: TCPPortProbe.probe)
    }

    package init(keys: any DeviceKeyStore, hosts: any PairedHostStore, transport: @escaping BridgeTransportFactory,
                probe: PortProbe? = nil, now: @escaping @Sendable () -> Date = { .now }) {
        self.keys = keys
        self.hosts = hosts
        self.transport = transport
        self.probe = probe
        self.now = now
    }

    public func pair(_ offer: PairingOffer) async throws -> PairedHost {
        // The bridge enforces expiry too; refusing early keeps a stale QR off the network.
        guard !offer.isExpired(at: now()) else { throw PairingError.expired }
        if offer.usesTLS { return try await enroll(offer) }
        let channel = NoiseChannel.pair(offer, identity: try keys.identity())
        // The same loop over the addresses as a reconnect, each with its own timeout. A
        // refused pairing code (the bridge answered and said no) ends it: another address won't
        // change that.
        let connection = HostConnection(endpoints: offer.addresses, channel: channel, transport: transport, probe: probe)
        do {
            try await connection.connect()
        } catch HostConnectionError.unreachable(let failures) {
            throw PairingError.unreachable(failures.map(\.description))
        }
        let endpoint = await connection.currentEndpoint ?? offer.addresses[0]
        await connection.disconnect()
        let others = offer.addresses.filter { $0 != endpoint }
        let host = PairedHost(name: offer.hostName, addresses: [endpoint] + others, hostKey: offer.hostKey, pairedAt: now())
        try hosts.save(host)
        return host
    }

    /// The channel for every connection after pairing.
    public func reconnectChannel(to host: PairedHost) throws -> NoiseChannel {
        NoiseChannel(identity: try keys.identity(), hostKey: host.hostKey, mode: .reconnect)
    }

    /// The connection to a paired host: IK over each saved address, the one that worked
    /// last first. When a different address works, it is saved first, so the next launch tries
    /// it first too.
    package func connection(to host: PairedHost, attemptTimeout: Duration = HostConnection.defaultAttemptTimeout) throws -> HostConnection {
        let store = hosts, id = host.id
        let saveAddresses: @Sendable ([HostEndpoint]) -> Void = { addresses in
            guard var saved = store.load().first(where: { $0.id == id }), saved.addresses != addresses else { return }
            saved.addresses = addresses
            try? store.update(saved)
        }
        if let deviceID = host.tlsDeviceID {
            let pin = Data(host.hostKey), key = Self.credential(pin: host.hostKey, deviceID: deviceID)
            return HostConnection(endpoints: host.addresses, channel: TLSChannel(), transport: { url in
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
        return HostConnection(endpoints: host.addresses, channel: try reconnectChannel(to: host), transport: transport,
                              attemptTimeout: attemptTimeout, probe: probe, onAddressesChange: saveAddresses)
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
