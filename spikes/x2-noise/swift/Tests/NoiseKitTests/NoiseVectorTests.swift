import CryptoKit
import Foundation
import Testing
@testable import NoiseKit

struct Vector: Decodable, Sendable, CustomTestStringConvertible {
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
}

let vectorsURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("../../../vectors/subset.json")

func loadVectors() -> [Vector] {
    struct File: Decodable { let vectors: [Vector] }
    guard let data = try? Data(contentsOf: vectorsURL),
          let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
    return file.vectors
}

func b(_ s: String) -> Bytes { unhex(s)! }
func kp(_ s: String?) throws -> KeyPair? { try s.map { try KeyPair(privateKey: b($0)) } }

@Suite struct NoiseVectorTests {
    static let vectors = loadVectors()

    @Test func vectorSetIsComplete() {
        let names = Set(Self.vectors.map(\.protocol_name))
        for p in ["IK", "IKpsk1", "IKpsk2", "XX"] {
            for c in ["ChaChaPoly", "AESGCM"] {
                #expect(names.contains("Noise_\(p)_25519_\(c)_SHA256"))
            }
        }
        #expect(Set(Self.vectors.map(\.source)).count == 2)
    }

    /// Replays an official vector: both sides use its fixed keys; every handshake and
    /// transport ciphertext must match byte for byte, and the payload must decrypt back.
    @Test(arguments: vectors) func officialVector(_ v: Vector) throws {
        var ini = try HandshakeState(protocolName: v.protocol_name, initiator: true, prologue: b(v.init_prologue),
                                     s: kp(v.init_static), e: kp(v.init_ephemeral),
                                     rs: v.init_remote_static.map(b), psks: (v.init_psks ?? []).map(b))
        var res = try HandshakeState(protocolName: v.protocol_name, initiator: false, prologue: b(v.resp_prologue),
                                     s: kp(v.resp_static), e: kp(v.resp_ephemeral),
                                     rs: nil, psks: (v.resp_psks ?? []).map(b))
        var tIni: Transport?, tRes: Transport?
        for (i, m) in v.messages.enumerated() {
            let fromInitiator = i % 2 == 0
            let ct: Bytes, pt: Bytes
            if tIni == nil {
                if fromInitiator {
                    ct = try ini.writeMessage(b(m.payload)); pt = try res.readMessage(ct)
                } else {
                    ct = try res.writeMessage(b(m.payload)); pt = try ini.readMessage(ct)
                }
                if ini.isComplete {
                    #expect(res.isComplete)
                    tIni = ini.transport; tRes = res.transport
                    #expect(ini.handshakeHash == res.handshakeHash)
                    if let h = v.handshake_hash { #expect(hex(ini.handshakeHash) == h) }
                    #expect(res.remoteStatic == ini.s?.publicKey || ini.s == nil)
                }
            } else if fromInitiator {
                ct = try tIni!.send.encrypt(b(m.payload)); pt = try tRes!.receive.decrypt(ct)
            } else {
                ct = try tRes!.send.encrypt(b(m.payload)); pt = try tIni!.receive.decrypt(ct)
            }
            #expect(hex(ct) == m.ciphertext, "message \(i)")
            #expect(hex(pt) == m.payload, "message \(i)")
        }
        #expect(tIni != nil)
    }
}

@Suite struct NoiseUnitTests {
    /// CryptoKit's HKDF (extract + expand, empty info) equals Noise's HKDF.
    @Test func hkdfMatchesCryptoKit() {
        let ck = Bytes(repeating: 7, count: 32), ikm = Bytes(repeating: 9, count: 32)
        let ours = hkdf(chainingKey: ck, ikm: ikm, outputs: 3).joined()
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: ck)
        let theirs = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data(), outputByteCount: 96)
        #expect(Array(ours) == theirs.withUnsafeBytes { Array($0) })
    }

    @Test func tamperedTransportMessageIsRejected() throws {
        let host = KeyPair(), phone = KeyPair()
        var i = try HandshakeState(protocolName: "Noise_IK_25519_ChaChaPoly_SHA256", initiator: true,
                                   s: phone, rs: host.publicKey)
        var r = try HandshakeState(protocolName: "Noise_IK_25519_ChaChaPoly_SHA256", initiator: false, s: host)
        _ = try r.readMessage(i.writeMessage())
        _ = try i.readMessage(r.writeMessage())
        var ti = i.transport!, tr = r.transport!
        var ct = try ti.send.encrypt(Bytes("hello".utf8))
        ct[0] ^= 1
        #expect(throws: NoiseError.decryptFailed) { try tr.receive.decrypt(ct) }
    }

    /// Pairing with IKpsk1: a wrong one-time secret fails at the host's first read, before
    /// the host sends anything.
    @Test func ikpsk1WrongSecretFailsFirstMessage() throws {
        let host = KeyPair(), phone = KeyPair()
        let name = "Noise_IKpsk1_25519_ChaChaPoly_SHA256"
        var i = try HandshakeState(protocolName: name, initiator: true, s: phone, rs: host.publicKey,
                                   psks: [Bytes(repeating: 1, count: 32)])
        var r = try HandshakeState(protocolName: name, initiator: false, s: host,
                                   psks: [Bytes(repeating: 2, count: 32)])
        let m1 = try i.writeMessage()
        #expect(throws: NoiseError.decryptFailed) { try r.readMessage(m1) }
    }

    /// Pairing with IKpsk2 (WireGuard's choice): the psk is mixed in at the end of message 2,
    /// so a wrong secret passes the host's first read; the host answers, and only the phone
    /// notices. The host learns the phone held the secret only from its first transport message.
    @Test func ikpsk2WrongSecretPassesFirstMessage() throws {
        let host = KeyPair(), phone = KeyPair()
        let name = "Noise_IKpsk2_25519_ChaChaPoly_SHA256"
        var i = try HandshakeState(protocolName: name, initiator: true, s: phone, rs: host.publicKey,
                                   psks: [Bytes(repeating: 1, count: 32)])
        var r = try HandshakeState(protocolName: name, initiator: false, s: host,
                                   psks: [Bytes(repeating: 2, count: 32)])
        _ = try r.readMessage(i.writeMessage())
        let m2 = try r.writeMessage()
        #expect(r.isComplete)
        #expect(throws: NoiseError.decryptFailed) { try i.readMessage(m2) }
    }

    /// IK: an initiator holding the wrong host key (a QR for another host, or a MITM) fails.
    @Test func wrongHostKeyFailsFirstMessage() throws {
        let host = KeyPair(), other = KeyPair(), phone = KeyPair()
        let name = "Noise_IK_25519_ChaChaPoly_SHA256"
        var i = try HandshakeState(protocolName: name, initiator: true, s: phone, rs: other.publicKey)
        var r = try HandshakeState(protocolName: name, initiator: false, s: host)
        #expect(throws: NoiseError.decryptFailed) { try r.readMessage(i.writeMessage()) }
    }
}
