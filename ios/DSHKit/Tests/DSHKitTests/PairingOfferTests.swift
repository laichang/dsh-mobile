@testable import DSHCore
import DSHTransport
import Foundation
import Testing

@Suite struct PairingOfferTests {
    static func b64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Written the way the bridge's URLSearchParams writes it (space as "+", ":" "," "[" "]" escaped).
    static func link(k: [UInt8] = .init(repeating: 1, count: 32), i: [UInt8] = .init(repeating: 2, count: 16),
                     s: [UInt8] = .init(repeating: 3, count: 32), a: String = "192.168.1.5%3A47801%2C%5Bfd7a%3A%3A1%5D%3A47801",
                     v: String = "2") -> String {
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

    @Test func versionTwoUsesTLSAndScopesCredentialsToTheHost() throws {
        #expect(PairingOffer.ParseError.unsupportedVersion("1").description.contains("new pairing code"))
        #expect(AddressFailure.reason(for: URLError(.serverCertificateUntrusted)).contains("scan a new pairing code"))
        #expect(throws: PairingOffer.ParseError.unsupportedVersion("1")) { try PairingOffer(string: Self.link(v: "1")) }
        #expect(throws: PairingOffer.ParseError.badField("a")) { try PairingOffer(string: Self.link(a: "user%40host%3A80", v: "2")) }
        let device = UUID().uuidString
        #expect(Pairing.credential(pin: [1], deviceID: device).account != Pairing.credential(pin: [2], deviceID: device).account)
    }

    @Test func rejectsMalformedOffers() {
        #expect(throws: PairingOffer.ParseError.unsupportedVersion("99")) { try PairingOffer(string: Self.link(v: "99")) }
        #expect(throws: PairingOffer.ParseError.badField("s")) { try PairingOffer(string: Self.link(s: [1, 2, 3])) }
        #expect(throws: PairingOffer.ParseError.badField("a")) { try PairingOffer(string: Self.link(a: "nope")) }
        #expect(throws: PairingOffer.ParseError.notAPairingLink) { try PairingOffer(string: "https://example.com/pair?v=1") }
        // The old stub link is not an offer.
        #expect(throws: PairingOffer.ParseError.self) { try PairingOffer(string: "dshm://pair?host=127.0.0.1&port=47801&secret=round-trip-stub") }
    }

    @Test func parsesAddresses() {
        #expect(HostEndpoint(address: "10.0.0.2:47810") == HostEndpoint(host: "10.0.0.2", port: 47810))
        #expect(HostEndpoint(address: "[::1]:1") == HostEndpoint(host: "::1", port: 1))
        #expect(HostEndpoint(address: "10.0.0.2") == nil)
        #expect(HostEndpoint(address: "10.0.0.2:0") == nil)
        #expect(HostEndpoint(host: "::1", port: 1).webSocketURL(path: "/").absoluteString == "wss://[::1]:1/")
    }
    @Test func upgradeIgnoresOldHostRecords() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FilePairedHostStore(url: dir.appending(path: "paired-hosts.json"))
        let legacy = PairedHost(name: "Old Mac", addresses: [.localBridge()], hostKey: [1])
        try store.save(legacy)
        #expect(store.load().isEmpty)
        #expect(throws: PairingError.self) { try Pairing(hosts: store).connection(to: legacy) }
        var enrolled = PairedHost(name: "Mac", addresses: [.localBridge()], hostKey: [2])
        enrolled.tlsDeviceID = UUID().uuidString
        try store.save(enrolled)
        #expect(store.load() == [enrolled])
    }
}
