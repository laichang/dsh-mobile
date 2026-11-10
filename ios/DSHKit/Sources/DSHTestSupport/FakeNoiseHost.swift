#if DEBUG
import DSHCore
import Foundation

/// In-process stand-in for the bridge's Noise side (bridge/src/pairing/handshake.ts + store.ts):
/// pairing offers, single use and expiry, the device registry, and refusals as WebSocket close
/// codes. Each connection decrypts into a `FakeBridge` connection to a `FakeHost`, so app tests run
/// pairing, reconnect, resume and a whole task over real Noise without a socket. Debug builds only.
public actor FakeNoiseHost {
    public nonisolated let hostKey: NoiseKeyPair
    public nonisolated let hostName: String
    private struct Offer { var secret: [UInt8]; var expiresAt: Date; var used: Bool }
    private var offers: [[UInt8]: Offer] = [:]
    public private(set) var devices: [[UInt8]] = []
    /// Connections refused, with the close reason the bridge would send.
    public private(set) var refusals: [String] = []
    /// Completed IK reconnect handshakes (Noise resume tests).
    public private(set) var reconnects = 0
    private let now: @Sendable () -> Date

    public init(hostName: String = "Fake Mac", now: @escaping @Sendable () -> Date = { .now }) {
        hostKey = NoiseKeyPair()
        self.hostName = hostName
        self.now = now
    }

    public func makeOffer(ttl: TimeInterval = 600, addresses: [HostEndpoint] = [HostEndpoint(host: "192.0.2.10", port: 47801)]) -> PairingOffer {
        let id = (0..<PairingWire.offerIDLength).map { _ in UInt8.random(in: 0...255) }
        let secret = (0..<PairingWire.secretLength).map { _ in UInt8.random(in: 0...255) }
        let expiresAt = now().addingTimeInterval(ttl)
        offers[id] = Offer(secret: secret, expiresAt: expiresAt, used: false)
        return PairingOffer(hostName: hostName, addresses: addresses, hostKey: hostKey.publicKey,
                            offerID: id, secret: secret, expiresAt: expiresAt)
    }

    /// A fresh `FakeHost` behind every connection (like `FakeBridge.factory`).
    public nonisolated func factory(script: FakeBridge.Script = .init()) -> BridgeTransportFactory {
        { _ in FakeNoiseConnection(host: self, inner: try FakeHost(script: script).connection()) }
    }

    /// Every connection reaches the same `FakeHost`: its tasks and event log outlive connections,
    /// so reconnecting over Noise (IK) can resume from the cursor.
    public nonisolated func factory(host inner: FakeHost) -> BridgeTransportFactory {
        { _ in FakeNoiseConnection(host: self, inner: try inner.connection()) }
    }

    struct Refused: Error { let code: PairingWire.CloseCode; let reason: String }

    /// Handles the app's first message; returns Noise message 2 and the transport.
    func accept(_ first: [UInt8]) throws -> (reply: [UInt8], transport: NoiseTransport, remote: [UInt8]) {
        guard first.count > 2, first[0] == PairingWire.version, let mode = PairingWire.Mode(rawValue: first[1]) else {
            throw refuse(.badHello, "bad first message")
        }
        switch mode {
        case .pair:
            let end = 2 + PairingWire.offerIDLength
            guard first.count > end else { throw refuse(.badHello, "bad first message") }
            let id = Array(first[2..<end])
            guard let offer = offers[id] else { throw refuse(.pairingRejected, "pairing secret unknown") }
            if offer.used { throw refuse(.pairingRejected, "pairing secret used") }
            if offer.expiresAt <= now() { throw refuse(.pairingRejected, "pairing secret expired") }
            var hs = try NoiseHandshakeState(protocolName: PairingWire.pairProtocol, initiator: false,
                                             prologue: PairingWire.prologue(Array(first[..<end])), s: hostKey, psks: [offer.secret])
            do { _ = try hs.readMessage(Array(first[end...])) } catch { throw refuse(.pairingRejected, "pairing secret wrong") }
            offers[id]?.used = true
            let reply = try hs.writeMessage()
            return (reply, hs.transport!, hs.remoteStatic!)
        case .reconnect:
            var hs = try NoiseHandshakeState(protocolName: PairingWire.reconnectProtocol, initiator: false,
                                             prologue: PairingWire.prologue(Array(first[..<2])), s: hostKey)
            do { _ = try hs.readMessage(Array(first[2...])) } catch { throw refuse(.handshakeFailed, "handshake failed") }
            guard devices.contains(hs.remoteStatic!) else { throw refuse(.deviceUnknown, "device not paired") }
            reconnects += 1
            let reply = try hs.writeMessage()
            return (reply, hs.transport!, hs.remoteStatic!)
        }
    }

    func register(_ device: [UInt8]) {
        if !devices.contains(device) { devices.append(device) }
    }

    private func refuse(_ code: PairingWire.CloseCode, _ reason: String) -> Refused {
        refusals.append(reason)
        return Refused(code: code, reason: reason)
    }
}

/// One connection to a `FakeNoiseHost`: Noise outside, `FakeBridge` inside.
actor FakeNoiseConnection: BridgeTransport {
    private let host: FakeNoiseHost
    private let inner: FakeBridge
    private var transport: NoiseTransport?
    private var remote: [UInt8] = []
    private var registered = false
    private var handshakeReply: Result<Data, any Error>?
    private var waiter: CheckedContinuation<Data, any Error>?

    init(host: FakeNoiseHost, inner: FakeBridge) {
        self.host = host
        self.inner = inner
    }

    func send(_ message: Data) async throws {
        guard var t = transport else {
            let result: Result<Data, any Error>
            do {
                let (reply, transport, remote) = try await host.accept(Array(message))
                self.transport = transport
                self.remote = remote
                result = .success(Data(reply))
            } catch let refused as FakeNoiseHost.Refused {
                result = .failure(BridgeTransportError.closed(code: refused.code.rawValue, reason: refused.reason))
            }
            if let waiter {
                self.waiter = nil
                waiter.resume(with: result)
            } else {
                handshakeReply = result
            }
            return
        }
        let plaintext = try t.receive.decrypt(Array(message))
        transport = t
        if !registered {
            registered = true
            await host.register(remote)
        }
        try await inner.send(Data(plaintext))
    }

    func receive() async throws -> Data {
        if let reply = handshakeReply {
            handshakeReply = nil
            return try reply.get()
        }
        if transport == nil {
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }
        let plaintext = try await inner.receive()
        return Data(try transport!.send.encrypt(Array(plaintext)))
    }

    func close() async {
        waiter?.resume(throwing: HostConnectionError.disconnected)
        waiter = nil
        await inner.close()
    }
}
#endif
