// Cross-language handshake: this process runs the Swift side in-process and spawns the TS
// peer (ts/src/peer.ts under `node`, or $NODE) over stdin/stdout pipes.
// Needs `npm ci` in ts/ (scripts/interop does this).
import Foundation
import Testing
@testable import NoiseKit

let tsPeer = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("../../../ts/src/peer.ts").standardized.path

struct PeerOutcome {
    var result: InteropResult?
    var error: Error?
    var status: Int32
    var stderr: String
}

func withTSPeer(_ args: [String: String], _ run: (FrameIO) throws -> InteropResult) throws -> PeerOutcome {
    signal(SIGPIPE, SIG_IGN) // the peer may exit before we write
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = [ProcessInfo.processInfo.environment["NODE"] ?? "node", tsPeer]
        + args.sorted { $0.key < $1.key }.flatMap { ["--\($0.key)", $0.value] }
    let toPeer = Pipe(), fromPeer = Pipe(), errPipe = Pipe()
    p.standardInput = toPeer
    p.standardOutput = fromPeer
    p.standardError = errPipe
    try p.run()
    let io = FileHandleFrameIO(input: fromPeer.fileHandleForReading, output: toPeer.fileHandleForWriting)
    var out = PeerOutcome(status: 0, stderr: "")
    do { out.result = try run(io) } catch { out.error = error }
    try? toPeer.fileHandleForWriting.close()
    out.stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    out.status = p.terminationStatus
    return out
}

let interopProtocols = [
    "Noise_IK_25519_ChaChaPoly_SHA256",
    "Noise_IK_25519_AESGCM_SHA256",
    "Noise_IKpsk1_25519_ChaChaPoly_SHA256",
    "Noise_IKpsk2_25519_ChaChaPoly_SHA256",
    "Noise_XX_25519_ChaChaPoly_SHA256",
]

func checkSuccess(_ o: PeerOutcome, me: KeyPair, peer: KeyPair, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(o.error == nil, "\(o.error.map { "\($0)" } ?? "") ts stderr: \(o.stderr)", sourceLocation: sourceLocation)
    #expect(o.status == 0, "\(o.stderr)", sourceLocation: sourceLocation)
    guard let r = o.result else { return }
    #expect(r.peerImpl == "ts", sourceLocation: sourceLocation)
    #expect(r.remoteStatic == peer.publicKey, sourceLocation: sourceLocation)
    #expect(o.stderr.contains("ok h=\(hex(r.handshakeHash)) rs=\(hex(me.publicKey))"), "\(o.stderr)",
            sourceLocation: sourceLocation)
}

@Suite(.serialized) struct InteropTests {
    @Test(arguments: interopProtocols) func swiftInitiatorTsResponder(_ name: String) throws {
        let phone = KeyPair(), host = KeyPair(), psk = KeyPair().publicKey
        var args = ["role": "responder", "protocol": name, "s": hex(host.privateKey.rawRepresentation.map { $0 })]
        if name.contains("psk") { args["psk"] = hex(psk) }
        let o = try withTSPeer(args) { io in
            try runInterop(InteropConfig(initiator: true, protocolName: name, s: phone,
                                         rs: name.contains("_IK") ? host.publicKey : nil,
                                         psk: name.contains("psk") ? psk : nil), io: io)
        }
        checkSuccess(o, me: phone, peer: host)
    }

    @Test(arguments: interopProtocols) func tsInitiatorSwiftResponder(_ name: String) throws {
        let phone = KeyPair(), host = KeyPair(), psk = KeyPair().publicKey
        var args = ["role": "initiator", "protocol": name, "s": hex(Array(phone.privateKey.rawRepresentation))]
        if name.contains("_IK") { args["rs"] = hex(host.publicKey) }
        if name.contains("psk") { args["psk"] = hex(psk) }
        let o = try withTSPeer(args) { io in
            try runInterop(InteropConfig(initiator: false, protocolName: name, s: host,
                                         psk: name.contains("psk") ? psk : nil), io: io)
        }
        checkSuccess(o, me: host, peer: phone)
    }

    @Test func pairingWrongSecretRejected() throws {
        let name = "Noise_IKpsk1_25519_ChaChaPoly_SHA256"
        let phone = KeyPair(), host = KeyPair()
        // TS phone, Swift host: the host's first read fails.
        let a = try withTSPeer(["role": "initiator", "protocol": name, "s": hex(Array(phone.privateKey.rawRepresentation)),
                                "rs": hex(host.publicKey), "psk": hex(Bytes(repeating: 1, count: 32))]) { io in
            try runInterop(InteropConfig(initiator: false, protocolName: name, s: host,
                                         psk: Bytes(repeating: 2, count: 32)), io: io)
        }
        #expect(a.error as? NoiseError == .decryptFailed)
        #expect(a.status == 1)
        // Swift phone, TS host: the TS host rejects message 1 and exits without answering.
        let b = try withTSPeer(["role": "responder", "protocol": name, "s": hex(Array(host.privateKey.rawRepresentation)),
                                "psk": hex(Bytes(repeating: 2, count: 32))]) { io in
            try runInterop(InteropConfig(initiator: true, protocolName: name, s: phone, rs: host.publicKey,
                                         psk: Bytes(repeating: 1, count: 32)), io: io)
        }
        #expect("\(b.error.map { "\($0)" } ?? "")".contains("peer closed"))
        #expect(b.status == 1)
        #expect(b.stderr.contains("decrypt failed"))
    }

    @Test func wrongHostKeyRejected() throws {
        let name = "Noise_IK_25519_ChaChaPoly_SHA256"
        let host = KeyPair()
        let o = try withTSPeer(["role": "responder", "protocol": name, "s": hex(Array(host.privateKey.rawRepresentation))]) { io in
            try runInterop(InteropConfig(initiator: true, protocolName: name, s: KeyPair(),
                                         rs: KeyPair().publicKey), io: io)
        }
        #expect("\(o.error.map { "\($0)" } ?? "")".contains("peer closed"))
        #expect(o.stderr.contains("decrypt failed"))
    }
}
