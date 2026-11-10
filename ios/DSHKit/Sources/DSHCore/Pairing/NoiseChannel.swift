import Foundation
import Synchronization

public enum NoiseChannelError: Error, Equatable, CustomStringConvertible {
    /// The bridge refused the pairing secret: unknown, expired, already used, or wrong.
    case pairingRejected(String)
    /// The bridge doesn't know this device (never paired with it, or revoked).
    case deviceUnknown
    /// The handshake failed: wrong host key, tampering, or a protocol mismatch.
    case handshakeFailed(String)
    /// The peer took the WebSocket but is no DSH bridge: it closed with a code that no
    /// bridge sends, sent text, or replied with something that is not Noise message 2.
    case notABridge(String)

    public var description: String {
        switch self {
        case .pairingRejected(let why): "the host refused the pairing code (\(why.isEmpty ? "rejected" : why))"
        case .deviceUnknown: "this host doesn't know this phone; pair again"
        case .handshakeFailed(let why): "secure handshake failed (\(why))"
        case .notABridge(let why): "the program on this port is not a DSH bridge (\(why))"
        }
    }
}

/// The app's Noise channel to a bridge: the initiator side of
/// bridge/src/pairing/handshake.ts.
/// - `.pair`: `Noise_IKpsk1_25519_ChaChaPoly_SHA256`, psk = the QR's one-time secret.
/// - `.reconnect`: `Noise_IK_25519_ChaChaPoly_SHA256` with the host key saved at pairing.
/// Works over any address: every frame is encrypted and the host is authenticated by its key.
public struct NoiseChannel: SecureChannel {
    public enum Mode: Sendable, Equatable {
        case pair(offerID: [UInt8], secret: [UInt8])
        case reconnect
    }

    public let name = "noise"
    public let path = "/"
    public let identity: NoiseKeyPair
    public let hostKey: [UInt8]
    public let mode: Mode
    /// Tests only: a fixed ephemeral key, to replay golden transcripts.
    let ephemeral: NoiseKeyPair?

    public init(identity: NoiseKeyPair, hostKey: [UInt8], mode: Mode) {
        self.init(identity: identity, hostKey: hostKey, mode: mode, ephemeral: nil)
    }

    init(identity: NoiseKeyPair, hostKey: [UInt8], mode: Mode, ephemeral: NoiseKeyPair?) {
        self.identity = identity
        self.hostKey = hostKey
        self.mode = mode
        self.ephemeral = ephemeral
    }

    public static func pair(_ offer: PairingOffer, identity: NoiseKeyPair) -> NoiseChannel {
        NoiseChannel(identity: identity, hostKey: offer.hostKey, mode: .pair(offerID: offer.offerID, secret: offer.secret))
    }

    public func validate(_ endpoint: HostEndpoint) throws {}

    /// The handshake's first message (header ‖ Noise message 1) and the state that reads the reply.
    func start() throws -> (first: [UInt8], state: NoiseHandshakeState) {
        let header: [UInt8], protocolName: String, psks: [[UInt8]]
        switch mode {
        case .pair(let offerID, let secret):
            header = PairingWire.header(.pair, offerID: offerID)
            protocolName = PairingWire.pairProtocol
            psks = [secret]
        case .reconnect:
            header = PairingWire.header(.reconnect)
            protocolName = PairingWire.reconnectProtocol
            psks = []
        }
        var hs = try NoiseHandshakeState(
            protocolName: protocolName, initiator: true, prologue: PairingWire.prologue(header),
            s: identity, e: ephemeral, rs: hostKey, psks: psks)
        return (header + (try hs.writeMessage()), hs)
    }

    /// Reads Noise message 2 and returns the transport cipher.
    static func finish(_ state: NoiseHandshakeState, reply: [UInt8]) throws -> NoiseFrameCipher {
        var hs = state
        let payload: [UInt8]
        // A bridge with another key refuses message 1 with a close 4002; a reply that does not
        // read as message 2 comes from a peer that is not a bridge (an echo, another protocol).
        do {
            payload = try hs.readMessage(reply)
        } catch {
            throw NoiseChannelError.notABridge("bad reply")
        }
        guard payload.isEmpty, let transport = hs.transport else { throw NoiseChannelError.notABridge("bad reply") }
        return NoiseFrameCipher(transport, handshakeHash: hs.handshakeHash)
    }

    public func establish(over transport: any BridgeTransport) async throws -> any FrameCipher {
        let (first, state) = try start()
        try await transport.send(Data(first))
        let reply: Data
        do {
            reply = try await transport.receive()
        } catch BridgeTransportError.closed(let code, let reason) {
            throw Self.refusal(code: code, reason: reason)
        } catch BridgeTransportError.unexpectedTextMessage {
            throw NoiseChannelError.notABridge("text message")
        }
        return try Self.finish(state, reply: Array(reply))
    }

    /// The bridge's refusals are its close codes. Any other code, except "going
    /// away" (1001, a bridge that shuts down) and "abnormal" (1006, no close frame), comes from a
    /// WebSocket server that is not a bridge.
    static func refusal(code: Int, reason: String) -> NoiseChannelError {
        let why = reason.isEmpty ? "closed \(code)" : reason
        return switch PairingWire.CloseCode(rawValue: code) {
        case .pairingRejected?: .pairingRejected(reason)
        case .deviceUnknown?: .deviceUnknown
        case .handshakeFailed?, .badHello?: .handshakeFailed(why)
        case nil: code == 1001 || code == 1006 ? .handshakeFailed(why) : .notABridge(why)
        }
    }
}

/// One Noise transport per connection: `seal` and `open` advance their nonces, so frames must be
/// sealed in the order they're sent (`HostConnection` sends from one ordered outbox).
public final class NoiseFrameCipher: FrameCipher {
    private let state: Mutex<NoiseTransport>
    public let handshakeHash: [UInt8]

    init(_ transport: NoiseTransport, handshakeHash: [UInt8]) {
        state = Mutex(transport)
        self.handshakeHash = handshakeHash
    }

    public func seal(_ plaintext: Data) throws -> Data {
        try state.withLock { Data(try $0.send.encrypt(Array(plaintext))) }
    }

    public func open(_ ciphertext: Data) throws -> Data {
        try state.withLock { Data(try $0.receive.decrypt(Array(ciphertext))) }
    }
}
