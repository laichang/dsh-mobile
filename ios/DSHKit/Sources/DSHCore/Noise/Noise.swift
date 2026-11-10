// Noise Protocol Framework (rev 34) on CryptoKit: DH 25519, ChaChaPoly or AESGCM, SHA256.
// Ported from the X2 spike (spikes/x2-noise/swift/Sources/NoiseKit/Noise.swift) for S1, with a
// `Noise` prefix on every type. Mirrors bridge/src/pairing/noise.ts. Proven by the official
// vectors (protocol/fixtures/noise/official-vectors.json) and the cross-language golden
// transcripts (protocol/fixtures/noise/transcripts.json). Hand-rolled and unaudited: see
//.
import CryptoKit
import Foundation

public typealias NoiseBytes = [UInt8]

public enum NoiseError: Error, Equatable, Sendable {
    case unsupportedProtocol(String)
    case badKey(String)
    case missingKey(String)
    case wrongPskCount(expected: Int, got: Int)
    case notMyTurn
    case handshakeComplete
    case handshakeNotComplete
    case messageTooLong(Int)
    case messageTooShort
    case decryptFailed
    case nonceExhausted
}

public let noiseMaxMessageLength = 65535
let noiseDHLen = 32
let noiseHashLen = 32
let noiseTagLen = 16

// MARK: - Protocol name

public enum NoiseCipherSuite: String, Sendable {
    case chaChaPoly = "ChaChaPoly"
    case aesGCM = "AESGCM"
}

public enum NoiseToken: String, Sendable {
    case e, s, ee, es, se, ss, psk
}

public struct NoiseHandshakePattern: Sendable {
    public let name: String
    public let initiatorPre: [NoiseToken]
    public let responderPre: [NoiseToken]
    public let messages: [[NoiseToken]]
    public var pskCount: Int { messages.joined().filter { $0 == .psk }.count }

    static let base: [String: (ipre: [NoiseToken], rpre: [NoiseToken], msgs: [[NoiseToken]])] = [
        "NN": ([], [], [[.e], [.e, .ee]]),
        "NK": ([], [.s], [[.e, .es], [.e, .ee]]),
        "XX": ([], [], [[.e], [.e, .ee, .s, .es], [.s, .se]]),
        "IK": ([], [.s], [[.e, .es, .s, .ss], [.e, .ee, .se]]),
        "IX": ([], [], [[.e, .s], [.e, .ee, .se, .s, .es]]),
        "KK": ([.s], [.s], [[.e, .es, .ss], [.e, .ee, .se]]),
    ]

    /// Parses e.g. "IK", "IKpsk2", "XXpsk0+psk3".
    public static func parse(_ name: String) throws -> NoiseHandshakePattern {
        let baseName = String(name.prefix { $0.isUppercase })
        guard let b = base[baseName] else { throw NoiseError.unsupportedProtocol(name) }
        var msgs = b.msgs
        let mods = name.dropFirst(baseName.count)
        if !mods.isEmpty {
            for mod in mods.split(separator: "+") {
                guard mod.hasPrefix("psk"), let n = Int(mod.dropFirst(3)), n <= msgs.count else {
                    throw NoiseError.unsupportedProtocol(name)
                }
                if n == 0 { msgs[0].insert(.psk, at: 0) } else { msgs[n - 1].append(.psk) }
            }
        }
        return NoiseHandshakePattern(name: name, initiatorPre: b.ipre, responderPre: b.rpre, messages: msgs)
    }
}

public struct NoiseProtocol: Sendable {
    public let name: String
    public let pattern: NoiseHandshakePattern
    public let cipher: NoiseCipherSuite

    /// "Noise_<pattern>_25519_<ChaChaPoly|AESGCM>_SHA256"
    public init(_ name: String) throws {
        let parts = name.split(separator: "_").map(String.init)
        guard parts.count == 5, parts[0] == "Noise", parts[2] == "25519", parts[4] == "SHA256",
              let cipher = NoiseCipherSuite(rawValue: parts[3])
        else { throw NoiseError.unsupportedProtocol(name) }
        self.name = name
        self.pattern = try NoiseHandshakePattern.parse(parts[1])
        self.cipher = cipher
    }
}

// MARK: - Crypto primitives (CryptoKit)

func noiseSHA256(_ data: NoiseBytes) -> NoiseBytes { Array(SHA256.hash(data: data)) }

func noiseHMAC(key: NoiseBytes, data: NoiseBytes) -> NoiseBytes {
    Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
}

/// Noise's HKDF (spec §4.3): HMAC-based, chaining key as salt, 2 or 3 outputs.
/// CryptoKit's HKDF<SHA256> would also fit (extract = HMAC(ck, ikm); expand with empty
/// info yields the same T(1)||T(2)||T(3)), but the explicit form mirrors the spec.
func noiseHKDF(chainingKey: NoiseBytes, ikm: NoiseBytes, outputs: Int) -> [NoiseBytes] {
    let temp = noiseHMAC(key: chainingKey, data: ikm)
    var out: [NoiseBytes] = []
    var prev: NoiseBytes = []
    for i in 1...outputs {
        prev = noiseHMAC(key: temp, data: prev + [UInt8(i)])
        out.append(prev)
    }
    return out
}

public struct NoiseKeyPair: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public var publicKey: NoiseBytes { Array(privateKey.publicKey.rawRepresentation) }
    /// The raw 32-byte secret, for the Keychain (`DeviceKeyStore`). Never log it.
    public var privateKeyBytes: NoiseBytes { Array(privateKey.rawRepresentation) }

    public init() { privateKey = .init() }
    public init(privateKey raw: NoiseBytes) throws {
        do { privateKey = try .init(rawRepresentation: raw) } catch { throw NoiseError.badKey("private key") }
    }
}

func noiseDH(_ kp: NoiseKeyPair, _ pub: NoiseBytes) throws -> NoiseBytes {
    do {
        let pk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub)
        return try kp.privateKey.sharedSecretFromKeyAgreement(with: pk).withUnsafeBytes { Array($0) }
    } catch {
        throw NoiseError.badKey("DH failed")
    }
}

// MARK: - NoiseCipherState (spec §5.1)

public struct NoiseCipherState: Sendable {
    let suite: NoiseCipherSuite
    var key: SymmetricKey?
    public private(set) var nonce: UInt64 = 0

    init(suite: NoiseCipherSuite) { self.suite = suite }

    var hasKey: Bool { key != nil }

    mutating func initializeKey(_ k: NoiseBytes?) {
        key = k.map { SymmetricKey(data: $0) }
        nonce = 0
    }

    /// 96-bit nonce: 32 zero bits, then the 64-bit counter (little-endian for ChaChaPoly,
    /// big-endian for AESGCM).
    func nonceBytes(_ n: UInt64) -> NoiseBytes {
        let counter = suite == .chaChaPoly ? n.littleEndian : n.bigEndian
        return [0, 0, 0, 0] + withUnsafeBytes(of: counter) { Array($0) }
    }

    func seal(_ key: SymmetricKey, _ n: UInt64, ad: NoiseBytes, _ pt: NoiseBytes) throws -> NoiseBytes {
        switch suite {
        case .chaChaPoly:
            let box = try ChaChaPoly.seal(pt, using: key, nonce: .init(data: nonceBytes(n)), authenticating: ad)
            return Array(box.ciphertext) + Array(box.tag)
        case .aesGCM:
            let box = try AES.GCM.seal(pt, using: key, nonce: .init(data: nonceBytes(n)), authenticating: ad)
            return Array(box.ciphertext) + Array(box.tag)
        }
    }

    func open(_ key: SymmetricKey, _ n: UInt64, ad: NoiseBytes, _ ct: NoiseBytes) throws -> NoiseBytes {
        guard ct.count >= noiseTagLen else { throw NoiseError.messageTooShort }
        let body = ct.prefix(ct.count - noiseTagLen), tag = ct.suffix(noiseTagLen)
        do {
            switch suite {
            case .chaChaPoly:
                let box = try ChaChaPoly.SealedBox(nonce: .init(data: nonceBytes(n)), ciphertext: body, tag: tag)
                return Array(try ChaChaPoly.open(box, using: key, authenticating: ad))
            case .aesGCM:
                let box = try AES.GCM.SealedBox(nonce: .init(data: nonceBytes(n)), ciphertext: body, tag: tag)
                return Array(try AES.GCM.open(box, using: key, authenticating: ad))
            }
        } catch {
            throw NoiseError.decryptFailed
        }
    }

    public mutating func encrypt(ad: NoiseBytes = [], _ plaintext: NoiseBytes) throws -> NoiseBytes {
        guard let key else { return plaintext }
        guard nonce != .max else { throw NoiseError.nonceExhausted }
        let ct = try seal(key, nonce, ad: ad, plaintext)
        nonce += 1
        return ct
    }

    public mutating func decrypt(ad: NoiseBytes = [], _ ciphertext: NoiseBytes) throws -> NoiseBytes {
        guard let key else { return ciphertext }
        guard nonce != .max else { throw NoiseError.nonceExhausted }
        let pt = try open(key, nonce, ad: ad, ciphertext)
        nonce += 1
        return pt
    }

    /// REKEY (spec §4.2): k = first 32 bytes of ENCRYPT(k, 2^64-1, empty, zeros).
    public mutating func rekey() throws {
        guard let key else { return }
        let k = try seal(key, .max, ad: [], NoiseBytes(repeating: 0, count: 32))
        self.key = SymmetricKey(data: k.prefix(32))
    }
}

// MARK: - NoiseSymmetricState (spec §5.2)

struct NoiseSymmetricState: Sendable {
    var cs: NoiseCipherState
    var ck: NoiseBytes
    var h: NoiseBytes

    init(protocol p: NoiseProtocol) {
        let name = Array(p.name.utf8)
        h = name.count <= noiseHashLen ? name + NoiseBytes(repeating: 0, count: noiseHashLen - name.count) : noiseSHA256(name)
        ck = h
        cs = NoiseCipherState(suite: p.cipher)
    }

    mutating func mixKey(_ ikm: NoiseBytes) {
        let o = noiseHKDF(chainingKey: ck, ikm: ikm, outputs: 2)
        ck = o[0]
        cs.initializeKey(o[1])
    }

    mutating func mixHash(_ data: NoiseBytes) { h = noiseSHA256(h + data) }

    mutating func mixKeyAndHash(_ ikm: NoiseBytes) {
        let o = noiseHKDF(chainingKey: ck, ikm: ikm, outputs: 3)
        ck = o[0]
        mixHash(o[1])
        cs.initializeKey(o[2])
    }

    mutating func encryptAndHash(_ pt: NoiseBytes) throws -> NoiseBytes {
        let ct = try cs.encrypt(ad: h, pt)
        mixHash(ct)
        return ct
    }

    mutating func decryptAndHash(_ ct: NoiseBytes) throws -> NoiseBytes {
        let pt = try cs.decrypt(ad: h, ct)
        mixHash(ct)
        return pt
    }

    func split() -> (NoiseCipherState, NoiseCipherState) {
        let o = noiseHKDF(chainingKey: ck, ikm: [], outputs: 2)
        var c1 = NoiseCipherState(suite: cs.suite), c2 = NoiseCipherState(suite: cs.suite)
        c1.initializeKey(o[0])
        c2.initializeKey(o[1])
        return (c1, c2)
    }
}

// MARK: - NoiseHandshakeState (spec §5.3)

public struct NoiseTransport: Sendable {
    public var send: NoiseCipherState
    public var receive: NoiseCipherState
}

public struct NoiseHandshakeState: Sendable {
    public let initiator: Bool
    let pattern: NoiseHandshakePattern
    var ss: NoiseSymmetricState
    let s: NoiseKeyPair?
    var e: NoiseKeyPair?
    public private(set) var remoteStatic: NoiseBytes?
    var re: NoiseBytes?
    var psks: [NoiseBytes]
    var messageIndex = 0
    public private(set) var transport: NoiseTransport?

    /// `e` is for test vectors only; in production leave it nil and a fresh one is generated.
    public init(protocolName: String, initiator: Bool, prologue: NoiseBytes = [], s: NoiseKeyPair? = nil,
                e: NoiseKeyPair? = nil, rs: NoiseBytes? = nil, psks: [NoiseBytes] = []) throws {
        let p = try NoiseProtocol(protocolName)
        guard psks.count == p.pattern.pskCount else {
            throw NoiseError.wrongPskCount(expected: p.pattern.pskCount, got: psks.count)
        }
        guard psks.allSatisfy({ $0.count == 32 }) else { throw NoiseError.badKey("psk must be 32 bytes") }
        if let rs, rs.count != noiseDHLen { throw NoiseError.badKey("remote static") }
        self.initiator = initiator
        self.pattern = p.pattern
        self.ss = NoiseSymmetricState(protocol: p)
        self.s = s
        self.e = e
        self.remoteStatic = rs
        self.psks = psks
        ss.mixHash(prologue)
        // Pre-messages: only "s" occurs in the supported patterns.
        for (tokens, mine) in [(pattern.initiatorPre, initiator), (pattern.responderPre, !initiator)] {
            for t in tokens where t == .s {
                if mine {
                    guard let s else { throw NoiseError.missingKey("local static") }
                    ss.mixHash(s.publicKey)
                } else {
                    guard let rs else { throw NoiseError.missingKey("remote static") }
                    ss.mixHash(rs)
                }
            }
        }
    }

    public var isComplete: Bool { transport != nil }
    public var isMyTurn: Bool { !isComplete && (messageIndex % 2 == 0) == initiator }
    public var handshakeHash: NoiseBytes { ss.h }

    var pskMode: Bool { pattern.pskCount > 0 }

    mutating func mixDH(_ t: NoiseToken) throws {
        func need<T>(_ v: T?, _ what: String) throws -> T {
            guard let v else { throw NoiseError.missingKey(what) }
            return v
        }
        switch t {
        case .ee: ss.mixKey(try noiseDH(need(e, "e"), need(re, "re")))
        case .ss: ss.mixKey(try noiseDH(need(s, "s"), need(remoteStatic, "rs")))
        case .es:
            ss.mixKey(initiator ? try noiseDH(need(e, "e"), need(remoteStatic, "rs"))
                                : try noiseDH(need(s, "s"), need(re, "re")))
        case .se:
            ss.mixKey(initiator ? try noiseDH(need(s, "s"), need(re, "re"))
                                : try noiseDH(need(e, "e"), need(remoteStatic, "rs")))
        case .psk:
            guard !psks.isEmpty else { throw NoiseError.missingKey("psk") }
            ss.mixKeyAndHash(psks.removeFirst())
        case .e, .s: preconditionFailure()
        }
    }

    public mutating func writeMessage(_ payload: NoiseBytes = []) throws -> NoiseBytes {
        guard !isComplete else { throw NoiseError.handshakeComplete }
        guard isMyTurn else { throw NoiseError.notMyTurn }
        var out: NoiseBytes = []
        for t in pattern.messages[messageIndex] {
            switch t {
            case .e:
                if e == nil { e = NoiseKeyPair() }
                let pub = e!.publicKey
                out += pub
                ss.mixHash(pub)
                if pskMode { ss.mixKey(pub) }
            case .s:
                guard let s else { throw NoiseError.missingKey("local static") }
                out += try ss.encryptAndHash(s.publicKey)
            default:
                try mixDH(t)
            }
        }
        out += try ss.encryptAndHash(payload)
        guard out.count <= noiseMaxMessageLength else { throw NoiseError.messageTooLong(out.count) }
        advance()
        return out
    }

    public mutating func readMessage(_ message: NoiseBytes) throws -> NoiseBytes {
        guard !isComplete else { throw NoiseError.handshakeComplete }
        guard !isMyTurn else { throw NoiseError.notMyTurn }
        guard message.count <= noiseMaxMessageLength else { throw NoiseError.messageTooLong(message.count) }
        var rest = message[...]
        func take(_ n: Int) throws -> NoiseBytes {
            guard rest.count >= n else { throw NoiseError.messageTooShort }
            defer { rest = rest.dropFirst(n) }
            return Array(rest.prefix(n))
        }
        for t in pattern.messages[messageIndex] {
            switch t {
            case .e:
                let pub = try take(noiseDHLen)
                re = pub
                ss.mixHash(pub)
                if pskMode { ss.mixKey(pub) }
            case .s:
                let ct = try take(ss.cs.hasKey ? noiseDHLen + noiseTagLen : noiseDHLen)
                remoteStatic = try ss.decryptAndHash(ct)
            default:
                try mixDH(t)
            }
        }
        let payload = try ss.decryptAndHash(Array(rest))
        advance()
        return payload
    }

    mutating func advance() {
        messageIndex += 1
        if messageIndex == pattern.messages.count {
            let (c1, c2) = ss.split()
            transport = initiator ? NoiseTransport(send: c1, receive: c2) : NoiseTransport(send: c2, receive: c1)
        }
    }
}

// MARK: - Hex (tests and fixtures)

public func noiseHex(_ b: NoiseBytes) -> String { b.map { String(format: "%02x", $0) }.joined() }

public func noiseUnhex(_ s: String) -> NoiseBytes? {
    guard s.count % 2 == 0 else { return nil }
    var out: NoiseBytes = []
    var idx = s.startIndex
    while idx < s.endIndex {
        let next = s.index(idx, offsetBy: 2)
        guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
        out.append(b)
        idx = next
    }
    return out
}
