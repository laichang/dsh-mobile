import DSHCore
import Observation

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
