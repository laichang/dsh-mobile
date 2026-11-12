#if DEBUG
import DSHCore
import DSHTestSupport
import DSHTransport
import Foundation
import Testing

@Suite struct HostCommandCompatibilityTests {
    @Test func helloResumeAndListUseTheSameHostLog() async throws {
        let connection: HostConnection
        if let path = ProcessInfo.processInfo.environment["DSHM_COMMAND_FIXTURE"] {
            struct Peer: Decodable { let address: String, pin: Data, bearer: String }
            let peer = try JSONDecoder().decode(Peer.self, from: Data(contentsOf: URL(filePath: path)))
            connection = HostConnection(endpoints: [try #require(HostEndpoint(address: peer.address))],
                                        spkiSHA256: peer.pin, authorization: "Bearer " + peer.bearer)
        } else {
            connection = HostConnection(endpoint: .localBridge(), transport: FakeHost().factory)
        }
        let commands = HostSync.HostConfig(key: "fixture", connection: connection).commands
        try await commands.connect()
        let resumed = try await commands.resume(logID: "", afterSeq: 0)
        let listing = try await commands.listTasks()
        #expect(!resumed.logID.isEmpty)
        #expect(listing.logID == resumed.logID)
        #expect(listing.hostName == resumed.hostName)
        await commands.disconnect()
    }
}
#endif
