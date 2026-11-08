@testable import DSHCore
import DSHProtocol
import DSHTestSupport
import Foundation
import Testing

private let noiseFixtures = GoldenFixtures.fixturesDir.appending(path: "noise")

private func b(_ s: String) -> [UInt8] { noiseUnhex(s)! }

// MARK: - Noise itself

struct NoiseVector: Decodable, Sendable, CustomTestStringConvertible {
    struct Message: Decodable, Sendable { let payload: String; let ciphertext: String }
    let source: String
    let protocol_name: String
    let init_prologue: String
    let init_psks: [String]?
    let init_static: String?
    let init_ephemeral: String
    let init_remote_static: String?
    let resp_prologue: String
    let resp_psks: [String]?
    let resp_static: String?
    let resp_ephemeral: String?
    let handshake_hash: String?
    let messages: [Message]

    var testDescription: String { "\(protocol_name) [\(source)]" }

    static func load() -> [NoiseVector] {
        struct File: Decodable { let vectors: [NoiseVector] }
        guard let data = try? Data(contentsOf: noiseFixtures.appending(path: "official-vectors.json")),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.vectors
    }
}

@Suite struct NoiseVectors {
    static let vectors = NoiseVector.load()

    @Test func vectorSetIsComplete() {
        let names = Set(Self.vectors.map(\.protocol_name))
        #expect(names.contains(PairingWire.pairProtocol))
        #expect(names.contains(PairingWire.reconnectProtocol))
    }

    /// Replays an official vector with its fixed keys; every ciphertext must match byte for byte.
    @Test(arguments: vectors) func officialVector(_ v: NoiseVector) throws {
        func kp(_ s: String?) throws -> NoiseKeyPair? { try s.map { try NoiseKeyPair(privateKey: b($0)) } }
        var ini = try NoiseHandshakeState(protocolName: v.protocol_name, initiator: true, prologue: b(v.init_prologue),
                                          s: kp(v.init_static), e: kp(v.init_ephemeral),
                                          rs: v.init_remote_static.map(b), psks: (v.init_psks ?? []).map(b))
        var res = try NoiseHandshakeState(protocolName: v.protocol_name, initiator: false, prologue: b(v.resp_prologue),
                                          s: kp(v.resp_static), e: kp(v.resp_ephemeral), psks: (v.resp_psks ?? []).map(b))
        var tIni: NoiseTransport?, tRes: NoiseTransport?
        for (i, m) in v.messages.enumerated() {
            let fromInitiator = i % 2 == 0
            let ct: [UInt8], pt: [UInt8]
            if tIni == nil {
                if fromInitiator { ct = try ini.writeMessage(b(m.payload)); pt = try res.readMessage(ct) }
                else { ct = try res.writeMessage(b(m.payload)); pt = try ini.readMessage(ct) }
                if ini.isComplete {
                    tIni = ini.transport; tRes = res.transport
                    if let h = v.handshake_hash { #expect(noiseHex(ini.handshakeHash) == h) }
                }
            } else if fromInitiator {
                ct = try tIni!.send.encrypt(b(m.payload)); pt = try tRes!.receive.decrypt(ct)
            } else {
                ct = try tRes!.send.encrypt(b(m.payload)); pt = try tIni!.receive.decrypt(ct)
            }
            #expect(noiseHex(ct) == m.ciphertext, "message \(i)")
            #expect(noiseHex(pt) == m.payload, "message \(i)")
        }
        #expect(tIni != nil)
    }
}

// MARK: - The bridge's wire

struct Transcript: Decodable, Sendable, CustomTestStringConvertible {
    struct Message: Decodable, Sendable { let from: String; let plaintext: String; let ciphertext: String }
    let name: String
    let protocolName: String
    let mode: UInt8
    let hostStatic: String
    let phoneStatic: String
    let phoneEphemeral: String
    let offerId: String?
    let secret: String?
    let first: String
    let reply: String
    let handshakeHash: String
    let transport: [Message]

    enum CodingKeys: String, CodingKey {
        case name, mode, hostStatic, phoneStatic, phoneEphemeral, offerId, secret, first, reply, handshakeHash, transport
        case protocolName = "protocol"
    }

    var testDescription: String { name }

    static func load() -> [Transcript] {
        struct File: Decodable { let transcripts: [Transcript] }
        guard let data = try? Data(contentsOf: noiseFixtures.appending(path: "transcripts.json")),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.transcripts
    }
}

@Suite struct NoiseChannelTests {
    static let transcripts = Transcript.load()

    @Test func transcriptsCoverBothModes() {
        #expect(Set(Self.transcripts.map(\.name)) == ["pair", "reconnect"])
    }

    /// The Swift half of protocol/fixtures/noise/transcripts.json (the TS half is
    /// bridge/test/pairing.test.ts): with the same fixed keys, the phone's first message must
    /// equal the bridge's expectation byte for byte, and the bridge's reply and frames must open.
    @Test(arguments: transcripts) func goldenTranscripts(_ t: Transcript) throws {
        let host = try NoiseKeyPair(privateKey: b(t.hostStatic))
        let mode: NoiseChannel.Mode = t.mode == PairingWire.Mode.pair.rawValue
            ? .pair(offerID: b(t.offerId!), secret: b(t.secret!)) : .reconnect
        let channel = NoiseChannel(identity: try NoiseKeyPair(privateKey: b(t.phoneStatic)), hostKey: host.publicKey,
                                   mode: mode, ephemeral: try NoiseKeyPair(privateKey: b(t.phoneEphemeral)))
        let (first, state) = try channel.start()
        #expect(noiseHex(first) == t.first)
        let cipher = try NoiseChannel.finish(state, reply: b(t.reply))
        #expect(noiseHex(cipher.handshakeHash) == t.handshakeHash)
        for m in t.transport {
            if m.from == "phone" {
                #expect(noiseHex(Array(try cipher.seal(Data(b(m.plaintext))))) == m.ciphertext)
            } else {
                #expect(noiseHex(Array(try cipher.open(Data(b(m.ciphertext))))) == m.plaintext)
            }
        }
        // The plaintext is a real Frame: Hello.
        let hello = try Dshm_V1_Frame(serializedBytes: Data(b(t.transport[0].plaintext)))
        #expect(hello.request.hello.protocolVersion == DSHProtocolInfo.version)
    }

    @Test func tamperedFrameIsRejected() throws {
        let t = try #require(Self.transcripts.first { $0.name == "reconnect" })
        let host = try NoiseKeyPair(privateKey: b(t.hostStatic))
        let channel = NoiseChannel(identity: try NoiseKeyPair(privateKey: b(t.phoneStatic)), hostKey: host.publicKey,
                                   mode: .reconnect, ephemeral: try NoiseKeyPair(privateKey: b(t.phoneEphemeral)))
        let (_, state) = try channel.start()
        let cipher = try NoiseChannel.finish(state, reply: b(t.reply))
        var ct = b(t.transport[1].ciphertext)
        ct[0] ^= 1
        #expect(throws: NoiseError.decryptFailed) { try cipher.open(Data(ct)) }
    }

    @Test func closeCodesMapToErrors() {
        #expect(NoiseChannel.refusal(code: 4001, reason: "pairing secret used") == .pairingRejected("pairing secret used"))
        #expect(NoiseChannel.refusal(code: 4003, reason: "device not paired") == .deviceUnknown)
        #expect(NoiseChannel.refusal(code: 4002, reason: "handshake failed") == .handshakeFailed("handshake failed"))
        #expect(NoiseChannel.refusal(code: 1006, reason: "") == .handshakeFailed("closed 1006"))
    }

    /// Unlike PlaintextChannel, Noise may reach any address: the payload is encrypted and the
    /// host is authenticated by its key.
    @Test(arguments: ["192.168.1.10", "100.101.102.103", "fd7a:115c::1", "mac.tailnet.ts.net"])
    func noiseAcceptsAnyAddress(host: String) throws {
        try NoiseChannel(identity: NoiseKeyPair(), hostKey: NoiseKeyPair().publicKey, mode: .reconnect)
            .validate(HostEndpoint(host: host, port: 47801))
    }
}

// MARK: - The pairing offer

@Suite struct PairingOfferTests {
    static func b64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Written the way the bridge's URLSearchParams writes it (space as "+", ":" "," "[" "]" escaped).
    static func link(k: [UInt8] = .init(repeating: 1, count: 32), i: [UInt8] = .init(repeating: 2, count: 16),
                     s: [UInt8] = .init(repeating: 3, count: 32), a: String = "192.168.1.5%3A47801%2C%5Bfd7a%3A%3A1%5D%3A47801",
                     v: String = "1") -> String {
        "dshm://pair?v=\(v)&n=Mac+mini&a=\(a)&k=\(b64url(k))&i=\(b64url(i))&s=\(b64url(s))&x=1893456000"
    }

    @Test func parsesBridgeOfferURL() throws {
        let offer = try PairingOffer(string: Self.link())
        #expect(offer.hostName == "Mac mini")
        #expect(offer.addresses == [HostEndpoint(host: "192.168.1.5", port: 47801), HostEndpoint(host: "fd7a::1", port: 47801)])
        #expect(offer.hostKey == .init(repeating: 1, count: 32))
        #expect(offer.offerID == .init(repeating: 2, count: 16))
        #expect(offer.secret == .init(repeating: 3, count: 32))
        #expect(offer.expiresAt == Date(timeIntervalSince1970: 1893456000))
        #expect(try PairingOffer(string: Self.link().replacingOccurrences(of: "+", with: "%20")).hostName == "Mac mini")
    }

    /// The offer URL the bridge wrote for the golden pair transcript (protocol/fixtures/noise).
    @Test func parsesGoldenOfferURL() throws {
        struct File: Decodable { let offerURL: String }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: noiseFixtures.appending(path: "transcripts.json")))
        let pair = try #require(Transcript.load().first { $0.name == "pair" })
        let offer = try PairingOffer(string: file.offerURL)
        #expect(offer.hostName == "Mac mini (S1)")
        #expect(offer.addresses.map(\.description) == ["192.168.1.5:47801", "[fd7a:115c:a1e0::1]:47801", "100.64.0.7:47801"])
        #expect(offer.hostKey == (try NoiseKeyPair(privateKey: b(pair.hostStatic))).publicKey)
        #expect(offer.offerID == b(pair.offerId!))
        #expect(offer.secret == b(pair.secret!))
        #expect(offer.expiresAt == Date(timeIntervalSince1970: 1_893_456_000))
    }

    @Test func rejectsMalformedOffers() {
        #expect(throws: PairingOffer.ParseError.unsupportedVersion("2")) { try PairingOffer(string: Self.link(v: "2")) }
        #expect(throws: PairingOffer.ParseError.badField("s")) { try PairingOffer(string: Self.link(s: [1, 2, 3])) }
        #expect(throws: PairingOffer.ParseError.badField("a")) { try PairingOffer(string: Self.link(a: "nope")) }
        #expect(throws: PairingOffer.ParseError.notAPairingLink) { try PairingOffer(string: "https://example.com/pair?v=1") }
        // T0's stub link is not an offer.
        #expect(throws: PairingOffer.ParseError.self) { try PairingOffer(string: "dshm://pair?host=127.0.0.1&port=47801&secret=t0-stub") }
    }

    @Test func parsesAddresses() {
        #expect(HostEndpoint(address: "10.0.0.2:47810") == HostEndpoint(host: "10.0.0.2", port: 47810))
        #expect(HostEndpoint(address: "[::1]:1") == HostEndpoint(host: "::1", port: 1))
        #expect(HostEndpoint(address: "10.0.0.2") == nil)
        #expect(HostEndpoint(address: "10.0.0.2:0") == nil)
        #expect(HostEndpoint(host: "::1", port: 1).webSocketURL(path: "/").absoluteString == "ws://[::1]:1/")
    }
}

// MARK: - Pairing end to end against FakeNoiseHost

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

@MainActor
@Suite struct PairingTests {
    /// Waits on the store with no polling (S12): `waitForStore` in StoreWait.swift. A short
    /// timeout here is raised to its 30 s, so a busy machine makes the test slower, not red.
    func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await waitForStore("", timeout: max(timeout, .seconds(30)), sourceLocation: sourceLocation, condition)
    }

    let clock = Clock()
    let keys = InMemoryDeviceKeyStore()
    let hosts = InMemoryPairedHostStore()

    func pairing(_ factory: @escaping BridgeTransportFactory) -> Pairing {
        let clock = clock
        return Pairing(keys: keys, hosts: hosts, transport: factory, now: { clock.now })
    }

    /// PLAN S1 in miniature: pair with IKpsk1, then a new connection reconnects with IK and runs
    /// the T0 task over Noise.
    @Test func pairsThenRunsTaskOverNoise() async throws {
        let host = FakeNoiseHost(now: { [clock] in clock.now })
        let offer = await host.makeOffer()
        let p = pairing(host.factory(script: .init(reply: ["over", " noise"], chunkDelay: .milliseconds(5))))
        let paired = try await p.pair(offer)
        #expect(paired.name == "Fake Mac")
        #expect(paired.hostKey == host.hostKey.publicKey)
        #expect(hosts.load() == [paired])
        #expect(await host.devices == [try keys.identity().publicKey])

        let connection = HostConnection(endpoint: paired.addresses[0], channel: try p.reconnectChannel(to: paired),
                                        transport: host.factory(script: .init(reply: ["over", " noise"], chunkDelay: .milliseconds(5))))
        #expect(connection.channelName == "noise")
        let store = TaskStore(connection: connection, prompt: "hi")
        await store.send()
        try await waitUntil { store.status == .completed }
        #expect(store.transcript == "over noise")
    }

    @Test func reusedSecretIsRejected() async throws {
        let host = FakeNoiseHost(now: { [clock] in clock.now })
        let offer = await host.makeOffer()
        _ = try await pairing(host.factory()).pair(offer)
        // Another phone with the same QR, or a second try: refused by the host.
        let other = Pairing(keys: InMemoryDeviceKeyStore(), hosts: InMemoryPairedHostStore(), transport: host.factory(), now: { [clock] in clock.now })
        await #expect(throws: NoiseChannelError.pairingRejected("pairing secret used")) { try await other.pair(offer) }
        #expect(await host.devices.count == 1)
    }

    @Test func expiredSecretIsRejectedByHost() async throws {
        // The phone's clock says the offer is fresh; the host's says it expired. The host wins.
        let hostClock = Clock()
        let host = FakeNoiseHost(now: { [hostClock] in hostClock.now })
        let offer = await host.makeOffer(ttl: 600)
        hostClock.advance(601)
        var lenient = offer
        lenient.expiresAt = .distantFuture
        await #expect(throws: NoiseChannelError.pairingRejected("pairing secret expired")) { try await pairing(host.factory()).pair(lenient) }
        #expect(hosts.load().isEmpty)
    }

    @Test func expiredOfferIsRefusedBeforeConnecting() async throws {
        let host = FakeNoiseHost(now: { [clock] in clock.now })
        let offer = await host.makeOffer(ttl: 600)
        clock.advance(601)
        let opened = Counter()
        await #expect(throws: PairingError.expired) {
            try await pairing({ _ in await opened.increment(); throw CancellationError() }).pair(offer)
        }
        #expect(await opened.value == 0)
    }

    @Test func wrongSecretIsRejected() async throws {
        let host = FakeNoiseHost(now: { [clock] in clock.now })
        var offer = await host.makeOffer()
        offer.secret = .init(repeating: 7, count: 32)
        await #expect(throws: NoiseChannelError.pairingRejected("pairing secret wrong")) { try await pairing(host.factory()).pair(offer) }
    }

    @Test func unpairedPhoneCannotReconnect() async throws {
        let host = FakeNoiseHost()
        let channel = NoiseChannel(identity: NoiseKeyPair(), hostKey: host.hostKey.publicKey, mode: .reconnect)
        let connection = HostConnection(endpoint: HostEndpoint(host: "192.0.2.10", port: 47801), channel: channel, transport: host.factory())
        await #expect(throws: NoiseChannelError.deviceUnknown) { try await connection.connect() }
    }

    @Test func unreachableAddressFallsThroughToNext() async throws {
        let host = FakeNoiseHost(now: { [clock] in clock.now })
        let offer = await host.makeOffer(addresses: [HostEndpoint(host: "192.0.2.1", port: 1), HostEndpoint(host: "192.0.2.2", port: 2)])
        let inner = host.factory()
        let paired = try await pairing({ url in
            if url.host() == "192.0.2.1" { throw URLError(.cannotConnectToHost) }
            return try await inner(url)
        }).pair(offer)
        #expect(paired.addresses.first == HostEndpoint(host: "192.0.2.2", port: 2))
    }

    /// S31: the failure names why each address failed; the bare "couldn't reach" hid an ATS refusal.
    @Test func unreachableNamesTheReasonForEachAddress() async throws {
        let host = FakeNoiseHost(now: { [clock] in clock.now })
        let offer = await host.makeOffer(addresses: [HostEndpoint(host: "100.79.171.34", port: 47801), HostEndpoint(host: "192.0.2.2", port: 2)])
        let failing = pairing({ url in
            if url.host() == "100.79.171.34" { throw URLError(.appTransportSecurityRequiresSecureConnection) }
            throw URLError(.cannotConnectToHost)
        })
        await #expect(throws: PairingError.unreachable([
            "100.79.171.34:47801 (URL error -1022, App Transport Security)",
            "192.0.2.2:2 (URL error -1004, connection refused)",
        ])) { try await failing.pair(offer) }
    }

    @Test func pairingModelReportsStates() async throws {
        let host = FakeNoiseHost(now: { [clock] in clock.now })
        let model = PairingModel(offer: await host.makeOffer(), pairing: pairing(host.factory()))
        #expect(model.state.token == "reviewing")
        await model.pair()
        #expect(model.state.token == "paired")
        let again = PairingModel(offer: model.offer, pairing: pairing(host.factory()))
        await again.pair()
        #expect(again.state.token == "failed")
    }
}
