// Interop peer: runs one side of the interop script over stdin/stdout.
// usage: noise-peer --role initiator|responder --protocol NAME --s HEX [--rs HEX] [--psk HEX]
//                   [--prologue HEX] [--pings N]
// On success prints "ok h=<hex> rs=<hex>" to stderr and exits 0; exits 1 on any failure.
import Foundation
import NoiseKit

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("noise-peer(swift): \(msg)\n".utf8))
    exit(1)
}

nonisolated(unsafe) var opts: [String: String] = [:]
var args = CommandLine.arguments.dropFirst()
while let k = args.popFirst() {
    guard k.hasPrefix("--"), let v = args.popFirst() else { fail("bad arguments") }
    opts[String(k.dropFirst(2))] = v
}
func bytes(_ k: String) -> Bytes? {
    guard let v = opts[k] else { return nil }
    guard let b = unhex(v) else { fail("--\(k) is not hex") }
    return b
}

guard let role = opts["role"], role == "initiator" || role == "responder" else { fail("--role") }
guard let proto = opts["protocol"] else { fail("--protocol") }
guard let sk = bytes("s") else { fail("--s") }

do {
    var c = InteropConfig(initiator: role == "initiator", protocolName: proto, s: try KeyPair(privateKey: sk),
                          rs: bytes("rs"), psk: bytes("psk"))
    if let p = bytes("prologue") { c.prologue = p }
    if let n = opts["pings"].flatMap(Int.init) { c.pings = n }
    let io = FileHandleFrameIO(input: .standardInput, output: .standardOutput)
    let r = try runInterop(c, io: io)
    FileHandle.standardError.write(Data("ok h=\(hex(r.handshakeHash)) rs=\(hex(r.remoteStatic ?? []))\n".utf8))
} catch {
    fail("\(error)")
}
