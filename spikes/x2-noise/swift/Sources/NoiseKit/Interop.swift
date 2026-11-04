// The cross-language interop script. ts/src/interop.ts implements the same steps; the two
// must stay in lockstep.
//
// Frames: 2-byte big-endian length, then the Noise message (handshake or transport).
// 1. Handshake: each side writes "hs<i> from <impl>" as the payload of message i.
// 2. Transport: the initiator sends "ping <n>" for n in 0..<pings; the responder answers
//    each with "pong <n> <impl>".
// 3. Bye: the initiator sends "bye <hex(h)>", the responder answers "bye <hex(h)>".
//    Each side checks the peer's handshake hash equals its own.
import Foundation

public protocol FrameIO {
    func readFrame() throws -> Bytes
    func writeFrame(_ frame: Bytes) throws
}

public struct InteropConfig: Sendable {
    public var initiator: Bool
    public var protocolName: String
    public var s: KeyPair
    public var rs: Bytes?
    public var psk: Bytes?
    public var prologue: Bytes
    public var pings: Int
    public var impl: String

    public init(initiator: Bool, protocolName: String, s: KeyPair, rs: Bytes? = nil, psk: Bytes? = nil,
                prologue: Bytes = Bytes("dshm/x2".utf8), pings: Int = 3, impl: String = "swift") {
        self.initiator = initiator
        self.protocolName = protocolName
        self.s = s
        self.rs = rs
        self.psk = psk
        self.prologue = prologue
        self.pings = pings
        self.impl = impl
    }
}

public struct InteropResult: Sendable {
    public var handshakeHash: Bytes
    public var remoteStatic: Bytes?
    public var peerImpl: String
    public var received: [String]
}

public struct InteropError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

public func runInterop(_ c: InteropConfig, io: FrameIO) throws -> InteropResult {
    var hs = try HandshakeState(protocolName: c.protocolName, initiator: c.initiator, prologue: c.prologue,
                                s: c.s, rs: c.rs, psks: c.psk.map { [$0] } ?? [])
    var received: [String] = []
    var peerImpl = ""
    var i = 0
    while !hs.isComplete {
        if hs.isMyTurn {
            try io.writeFrame(hs.writeMessage(Bytes("hs\(i) from \(c.impl)".utf8)))
        } else {
            let text = String(decoding: try hs.readMessage(io.readFrame()), as: UTF8.self)
            guard text.hasPrefix("hs\(i) from ") else { throw InteropError("bad handshake payload: \(text)") }
            peerImpl = String(text.dropFirst("hs\(i) from ".count))
            received.append(text)
        }
        i += 1
    }
    var t = hs.transport!
    let h = hex(hs.handshakeHash)
    func send(_ s: String) throws { try io.writeFrame(t.send.encrypt(Bytes(s.utf8))) }
    func recv() throws -> String {
        let s = String(decoding: try t.receive.decrypt(io.readFrame()), as: UTF8.self)
        received.append(s)
        return s
    }
    func expect(_ want: String) throws {
        let got = try recv()
        guard got == want else { throw InteropError("expected \"\(want)\", got \"\(got)\"") }
    }
    if c.initiator {
        for n in 0..<c.pings {
            try send("ping \(n)")
            try expect("pong \(n) \(peerImpl)")
        }
        try send("bye \(h)")
        try expect("bye \(h)")
    } else {
        for n in 0..<c.pings {
            try expect("ping \(n)")
            try send("pong \(n) \(c.impl)")
        }
        try expect("bye \(h)")
        try send("bye \(h)")
    }
    return InteropResult(handshakeHash: hs.handshakeHash, remoteStatic: hs.remoteStatic,
                         peerImpl: peerImpl, received: received)
}

/// Length-prefixed frames over a pair of file handles (stdio, pipes).
public final class FileHandleFrameIO: FrameIO {
    let input: FileHandle
    let output: FileHandle

    public init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    func readExactly(_ n: Int) throws -> Bytes {
        var buf: Bytes = []
        while buf.count < n {
            guard let chunk = try input.read(upToCount: n - buf.count), !chunk.isEmpty else {
                throw InteropError("peer closed the stream")
            }
            buf += chunk
        }
        return buf
    }

    public func readFrame() throws -> Bytes {
        let len = try readExactly(2)
        return try readExactly(Int(len[0]) << 8 | Int(len[1]))
    }

    public func writeFrame(_ frame: Bytes) throws {
        precondition(frame.count <= maxMessageLength)
        try output.write(contentsOf: Data([UInt8(frame.count >> 8), UInt8(frame.count & 0xff)] + frame))
    }
}

public func hex(_ b: Bytes) -> String { b.map { String(format: "%02x", $0) }.joined() }

public func unhex(_ s: String) -> Bytes? {
    guard s.count % 2 == 0 else { return nil }
    var out: Bytes = []
    var idx = s.startIndex
    while idx < s.endIndex {
        let next = s.index(idx, offsetBy: 2)
        guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
        out.append(b)
        idx = next
    }
    return out
}
