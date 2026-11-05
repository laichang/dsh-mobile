import Foundation

/// How a Noise connection starts on the bridge's WebSocket (ARCHITECTURE D6, D21). Mirrors
/// bridge/src/pairing/wire.ts; protocol/fixtures/noise/transcripts.json keeps the two in step.
///
/// The app's first binary message is a short header followed by Noise message 1:
///
///     pair:      [wireVersion, Mode.pair, offerID (16 bytes)] ‖ IKpsk1 message 1
///     reconnect: [wireVersion, Mode.reconnect]                ‖ IK message 1
///
/// The header is bound into the prologue ("dshm/1" ‖ header). The bridge answers with Noise
/// message 2. Handshake payloads are empty; then each WebSocket message is one Noise transport
/// message carrying one protobuf `Frame`.
public enum PairingWire {
    public static let version: UInt8 = 1
    public static let prologueLabel = "dshm/1"
    public static let pairProtocol = "Noise_IKpsk1_25519_ChaChaPoly_SHA256"
    public static let reconnectProtocol = "Noise_IK_25519_ChaChaPoly_SHA256"
    public static let offerIDLength = 16
    public static let secretLength = 32
    public static let keyLength = 32

    public enum Mode: UInt8, Sendable {
        case pair = 1
        case reconnect = 2
    }

    /// WebSocket close codes the bridge uses to refuse a Noise connection.
    public enum CloseCode: Int, Sendable {
        case badHello = 4000
        /// The offer is unknown, expired, already used, or the secret is wrong.
        case pairingRejected = 4001
        /// Wrong host key, tampering, bad payload.
        case handshakeFailed = 4002
        /// Reconnect from a device the bridge doesn't know (never paired, or revoked).
        case deviceUnknown = 4003
    }

    public static func header(_ mode: Mode, offerID: [UInt8]? = nil) -> [UInt8] {
        switch mode {
        case .pair:
            precondition(offerID?.count == offerIDLength, "pairing needs a 16-byte offer id")
            return [version, mode.rawValue] + offerID!
        case .reconnect:
            return [version, mode.rawValue]
        }
    }

    public static func prologue(_ header: [UInt8]) -> [UInt8] {
        Array(prologueLabel.utf8) + header
    }
}
