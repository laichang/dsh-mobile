import Foundation
import Observation

public enum PairingError: Error, Equatable, CustomStringConvertible {
    case expired
    case unreachable([String])

    public var description: String {
        switch self {
        case .expired: "this pairing code has expired; show a new one on the host"
        case .unreachable(let tried): "couldn't reach the host at \(tried.joined(separator: ", "))"
        }
    }
}

/// Pairs with the host behind a QR offer (PLAN S1): tries each address in order, runs the
/// `IKpsk1` handshake and Hello, then saves the host. Later connections use `IK`
/// (`NoiseChannel` `.reconnect`) with the saved host key.
public struct Pairing: Sendable {
    public let keys: any DeviceKeyStore
    public let hosts: any PairedHostStore
    public let transport: BridgeTransportFactory
    public let now: @Sendable () -> Date

    public init(keys: any DeviceKeyStore, hosts: any PairedHostStore, transport: @escaping BridgeTransportFactory,
                now: @escaping @Sendable () -> Date = { .now }) {
        self.keys = keys
        self.hosts = hosts
        self.transport = transport
        self.now = now
    }

    public func pair(_ offer: PairingOffer) async throws -> PairedHost {
        // The bridge enforces expiry too; refusing early keeps a stale QR off the network.
        guard !offer.isExpired(at: now()) else { throw PairingError.expired }
        let channel = NoiseChannel.pair(offer, identity: try keys.identity())
        var tried: [String] = []
        for endpoint in offer.addresses {
            let connection = HostConnection(endpoint: endpoint, channel: channel, transport: transport)
            do {
                try await connection.connect()
            } catch let error as NoiseChannelError {
                // The bridge answered and said no: another address won't change that.
                throw error
            } catch {
                tried.append(endpoint.description)
                continue
            }
            await connection.disconnect()
            let others = offer.addresses.filter { $0 != endpoint }
            let host = PairedHost(name: offer.hostName, addresses: [endpoint] + others, hostKey: offer.hostKey, pairedAt: now())
            try hosts.save(host)
            return host
        }
        throw PairingError.unreachable(tried)
    }

    /// The channel for every connection after pairing.
    public func reconnectChannel(to host: PairedHost) throws -> NoiseChannel {
        NoiseChannel(identity: try keys.identity(), hostKey: host.hostKey, mode: .reconnect)
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

    public let offer: PairingOffer
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
