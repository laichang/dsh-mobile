// Noise Protocol Framework (rev 34) on CryptoKit: DH 25519, ChaChaPoly or AESGCM, SHA256.
// X2 spike code: correct against the official vectors, but not hardened or reviewed.
import CryptoKit
import Foundation

public typealias Bytes = [UInt8]

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

public let maxMessageLength = 65535
let dhLen = 32
let hashLen = 32
let tagLen = 16

// MARK: - Protocol name

public enum CipherSuite: String, Sendable {
    case chaChaPoly = "ChaChaPoly"
    case aesGCM = "AESGCM"
}

public enum Token: String, Sendable {
    case e, s, ee, es, se, ss, psk
}

public struct HandshakePattern: Sendable {
    public let name: String
    public let initiatorPre: [Token]
    public let responderPre: [Token]
    public let messages: [[Token]]
    public var pskCount: Int { messages.joined().filter { $0 == .psk }.count }

    static let base: [String: (ipre: [Token], rpre: [Token], msgs: [[Token]])] = [
        "NN": ([], [], [[.e], [.e, .ee]]),
        "NK": ([], [.s], [[.e, .es], [.e, .ee]]),
        "XX": ([], [], [[.e], [.e, .ee, .s, .es], [.s, .se]]),
        "IK": ([], [.s], [[.e, .es, .s, .ss], [.e, .ee, .se]]),
        "IX": ([], [], [[.e, .s], [.e, .ee, .se, .s, .es]]),
        "KK": ([.s], [.s], [[.e, .es, .ss], [.e, .ee, .se]]),
    ]

    /// Parses e.g. "IK", "IKpsk2", "XXpsk0+psk3".
    public static func parse(_ name: String) throws -> HandshakePattern {
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
        return HandshakePattern(name: name, initiatorPre: b.ipre, responderPre: b.rpre, messages: msgs)
    }
}

public struct NoiseProtocol: Sendable {
    public let name: String
    public let pattern: HandshakePattern
    public let cipher: CipherSuite

    /// "Noise_<pattern>_25519_<ChaChaPoly|AESGCM>_SHA256"
    public init(_ name: String) throws {
        let parts = name.split(separator: "_").map(String.init)
        guard parts.count == 5, parts[0] == "Noise", parts[2] == "25519", parts[4] == "SHA256",
              let cipher = CipherSuite(rawValue: parts[3])
        else { throw NoiseError.unsupportedProtocol(name) }
        self.name = name
        self.pattern = try HandshakePattern.parse(parts[1])
        self.cipher = cipher
    }
}

// MARK: - Crypto primitives (CryptoKit)

func sha256(_ data: Bytes) -> Bytes { Array(SHA256.hash(data: data)) }

func hmacSHA256(key: Bytes, data: Bytes) -> Bytes {
    Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
}

/// Noise's HKDF (spec §4.3): HMAC-based, chaining key as salt, 2 or 3 outputs.
/// CryptoKit's HKDF<SHA256> would also fit (extract = HMAC(ck, ikm); expand with empty
/// info yields the same T(1)||T(2)||T(3)), but the explicit form mirrors the spec.
func hkdf(chainingKey: Bytes, ikm: Bytes, outputs: Int) -> [Bytes] {
    let temp = hmacSHA256(key: chainingKey, data: ikm)
    var out: [Bytes] = []
    var prev: Bytes = []
    for i in 1...outputs {
        prev = hmacSHA256(key: temp, data: prev + [UInt8(i)])
        out.append(prev)
    }
    return out
}

public struct KeyPair: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public var publicKey: Bytes { Array(privateKey.publicKey.rawRepresentation) }

    public init() { privateKey = .init() }
    public init(privateKey raw: Bytes) throws {
        do { privateKey = try .init(rawRepresentation: raw) } catch { throw NoiseError.badKey("private key") }
    }
}

func dh(_ kp: KeyPair, _ pub: Bytes) throws -> Bytes {
    do {
        let pk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub)
        return try kp.privateKey.sharedSecretFromKeyAgreement(with: pk).withUnsafeBytes { Array($0) }
    } catch {
        throw NoiseError.badKey("DH failed")
    }
}

// MARK: - CipherState (spec §5.1)

public struct CipherState: Sendable {
    let suite: CipherSuite
    var key: SymmetricKey?
    public private(set) var nonce: UInt64 = 0

    init(suite: CipherSuite) { self.suite = suite }

    var hasKey: Bool { key != nil }

    mutating func initializeKey(_ k: Bytes?) {
        key = k.map { SymmetricKey(data: $0) }
        nonce = 0
    }

    /// 96-bit nonce: 32 zero bits, then the 64-bit counter (little-endian for ChaChaPoly,
    /// big-endian for AESGCM).
    func nonceBytes(_ n: UInt64) -> Bytes {
        let counter = suite == .chaChaPoly ? n.littleEndian : n.bigEndian
        return [0, 0, 0, 0] + withUnsafeBytes(of: counter) { Array($0) }
    }

    func seal(_ key: SymmetricKey, _ n: UInt64, ad: Bytes, _ pt: Bytes) throws -> Bytes {
        switch suite {
        case .chaChaPoly:
            let box = try ChaChaPoly.seal(pt, using: key, nonce: .init(data: nonceBytes(n)), authenticating: ad)
            return Array(box.ciphertext) + Array(box.tag)
        case .aesGCM:
            let box = try AES.GCM.seal(pt, using: key, nonce: .init(data: nonceBytes(n)), authenticating: ad)
            return Array(box.ciphertext) + Array(box.tag)
        }
    }

    func open(_ key: SymmetricKey, _ n: UInt64, ad: Bytes, _ ct: Bytes) throws -> Bytes {
        guard ct.count >= tagLen else { throw NoiseError.messageTooShort }
        let body = ct.prefix(ct.count - tagLen), tag = ct.suffix(tagLen)
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

    public mutating func encrypt(ad: Bytes = [], _ plaintext: Bytes) throws -> Bytes {
        guard let key else { return plaintext }
        guard nonce != .max else { throw NoiseError.nonceExhausted }
        let ct = try seal(key, nonce, ad: ad, plaintext)
        nonce += 1
        return ct
    }

    public mutating func decrypt(ad: Bytes = [], _ ciphertext: Bytes) throws -> Bytes {
        guard let key else { return ciphertext }
        guard nonce != .max else { throw NoiseError.nonceExhausted }
        let pt = try open(key, nonce, ad: ad, ciphertext)
        nonce += 1
        return pt
    }

    /// REKEY (spec §4.2): k = first 32 bytes of ENCRYPT(k, 2^64-1, empty, zeros).
    public mutating func rekey() throws {
        guard let key else { return }
        let k = try seal(key, .max, ad: [], Bytes(repeating: 0, count: 32))
        self.key = SymmetricKey(data: k.prefix(32))
    }
}

// MARK: - SymmetricState (spec §5.2)

struct SymmetricState: Sendable {
    var cs: CipherState
    var ck: Bytes
    var h: Bytes

    init(protocol p: NoiseProtocol) {
        let name = Array(p.name.utf8)
        h = name.count <= hashLen ? name + Bytes(repeating: 0, count: hashLen - name.count) : sha256(name)
        ck = h
        cs = CipherState(suite: p.cipher)
    }

    mutating func mixKey(_ ikm: Bytes) {
        let o = hkdf(chainingKey: ck, ikm: ikm, outputs: 2)
        ck = o[0]
        cs.initializeKey(o[1])
    }

    mutating func mixHash(_ data: Bytes) { h = sha256(h + data) }

    mutating func mixKeyAndHash(_ ikm: Bytes) {
        let o = hkdf(chainingKey: ck, ikm: ikm, outputs: 3)
        ck = o[0]
        mixHash(o[1])
        cs.initializeKey(o[2])
    }

    mutating func encryptAndHash(_ pt: Bytes) throws -> Bytes {
        let ct = try cs.encrypt(ad: h, pt)
        mixHash(ct)
        return ct
    }

    mutating func decryptAndHash(_ ct: Bytes) throws -> Bytes {
        let pt = try cs.decrypt(ad: h, ct)
        mixHash(ct)
        return pt
    }

    func split() -> (CipherState, CipherState) {
        let o = hkdf(chainingKey: ck, ikm: [], outputs: 2)
        var c1 = CipherState(suite: cs.suite), c2 = CipherState(suite: cs.suite)
        c1.initializeKey(o[0])
        c2.initializeKey(o[1])
        return (c1, c2)
    }
}

// MARK: - HandshakeState (spec §5.3)

public struct Transport: Sendable {
    public var send: CipherState
    public var receive: CipherState
}

public struct HandshakeState: Sendable {
    public let initiator: Bool
    let pattern: HandshakePattern
    var ss: SymmetricState
    let s: KeyPair?
    var e: KeyPair?
    public private(set) var remoteStatic: Bytes?
    var re: Bytes?
    var psks: [Bytes]
    var messageIndex = 0
    public private(set) var transport: Transport?

    /// `e` is for test vectors only; in production leave it nil and a fresh one is generated.
    public init(protocolName: String, initiator: Bool, prologue: Bytes = [], s: KeyPair? = nil,
                e: KeyPair? = nil, rs: Bytes? = nil, psks: [Bytes] = []) throws {
        let p = try NoiseProtocol(protocolName)
        guard psks.count == p.pattern.pskCount else {
            throw NoiseError.wrongPskCount(expected: p.pattern.pskCount, got: psks.count)
        }
        guard psks.allSatisfy({ $0.count == 32 }) else { throw NoiseError.badKey("psk must be 32 bytes") }
        if let rs, rs.count != dhLen { throw NoiseError.badKey("remote static") }
        self.initiator = initiator
        self.pattern = p.pattern
        self.ss = SymmetricState(protocol: p)
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
    public var handshakeHash: Bytes { ss.h }

    var pskMode: Bool { pattern.pskCount > 0 }

    mutating func mixDH(_ t: Token) throws {
        func need<T>(_ v: T?, _ what: String) throws -> T {
            guard let v else { throw NoiseError.missingKey(what) }
            return v
        }
        switch t {
        case .ee: ss.mixKey(try dh(need(e, "e"), need(re, "re")))
        case .ss: ss.mixKey(try dh(need(s, "s"), need(remoteStatic, "rs")))
        case .es:
            ss.mixKey(initiator ? try dh(need(e, "e"), need(remoteStatic, "rs"))
                                : try dh(need(s, "s"), need(re, "re")))
        case .se:
            ss.mixKey(initiator ? try dh(need(s, "s"), need(re, "re"))
                                : try dh(need(e, "e"), need(remoteStatic, "rs")))
        case .psk:
            guard !psks.isEmpty else { throw NoiseError.missingKey("psk") }
            ss.mixKeyAndHash(psks.removeFirst())
        case .e, .s: preconditionFailure()
        }
    }

    public mutating func writeMessage(_ payload: Bytes = []) throws -> Bytes {
        guard !isComplete else { throw NoiseError.handshakeComplete }
        guard isMyTurn else { throw NoiseError.notMyTurn }
        var out: Bytes = []
        for t in pattern.messages[messageIndex] {
            switch t {
            case .e:
                if e == nil { e = KeyPair() }
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
        guard out.count <= maxMessageLength else { throw NoiseError.messageTooLong(out.count) }
        advance()
        return out
    }

    public mutating func readMessage(_ message: Bytes) throws -> Bytes {
        guard !isComplete else { throw NoiseError.handshakeComplete }
        guard !isMyTurn else { throw NoiseError.notMyTurn }
        guard message.count <= maxMessageLength else { throw NoiseError.messageTooLong(message.count) }
        var rest = message[...]
        func take(_ n: Int) throws -> Bytes {
            guard rest.count >= n else { throw NoiseError.messageTooShort }
            defer { rest = rest.dropFirst(n) }
            return Array(rest.prefix(n))
        }
        for t in pattern.messages[messageIndex] {
            switch t {
            case .e:
                let pub = try take(dhLen)
                re = pub
                ss.mixHash(pub)
                if pskMode { ss.mixKey(pub) }
            case .s:
                let ct = try take(ss.cs.hasKey ? dhLen + tagLen : dhLen)
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
            transport = initiator ? Transport(send: c1, receive: c2) : Transport(send: c2, receive: c1)
        }
    }
}
