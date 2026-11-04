import DSHProtocol
import Foundation
import SwiftProtobuf
import Testing

/// The Swift half of PLAN §1 "Cross-language truth": the TS half is bridge/test/fixtures.test.ts.
@Suite struct GoldenFixtures {
    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // DSHKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // DSHKit
        .deletingLastPathComponent()  // ios
        .deletingLastPathComponent()  // repo root
        .appending(path: "protocol/fixtures")

    struct Fixture {
        let name: String
        let frameJSON: Data
    }

    static func load() throws -> [Fixture] {
        let manifest = try Data(contentsOf: fixturesDir.appending(path: "fixtures.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        let entries = try #require(root["fixtures"] as? [[String: Any]])
        return try entries.map { entry in
            Fixture(
                name: try #require(entry["name"] as? String),
                frameJSON: try JSONSerialization.data(withJSONObject: try #require(entry["frame"]))
            )
        }
    }

    @Test func fixturesRoundTrip() throws {
        let fixtures = try Self.load()
        #expect(fixtures.count >= 9)
        for fixture in fixtures {
            let bytes = try Data(contentsOf: Self.fixturesDir.appending(path: "\(fixture.name).binpb"))
            let decoded = try Dshm_V1_Frame(serializedBytes: bytes)
            let fromJSON = try Dshm_V1_Frame(jsonUTF8Data: fixture.frameJSON)
            #expect(decoded == fromJSON, "\(fixture.name): binary and JSON disagree")
            #expect(try decoded.serializedData() == bytes, "\(fixture.name): re-encoded bytes differ")
        }
    }

    @Test func helloFixtureMatchesProtocolInfo() throws {
        let bytes = try Data(contentsOf: Self.fixturesDir.appending(path: "t0_hello_response.binpb"))
        let frame = try Dshm_V1_Frame(serializedBytes: bytes)
        #expect(frame.response.hello.protocolVersion == DSHProtocolInfo.version)
        #expect(frame.response.hello.capabilities == [DSHProtocolInfo.tasksCapability])
    }
}
