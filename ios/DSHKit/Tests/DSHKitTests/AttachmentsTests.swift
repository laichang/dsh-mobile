import DSHCore
import DSHProtocol
import DSHTestSupport
import Foundation
import Testing

/// Attachments (ARCHITECTURE D95): the Swift half of the golden upload. The TS half is
/// bridge/test/attachments.test.ts; both read protocol/fixtures/attachments/.
@MainActor
@Suite(.serialized) struct AttachmentsTests {
    struct Fixture: Decodable {
        struct Part: Decodable { let size: Int; let sha256: String }
        let file: String, name: String, mediaType: String, size: Int, sha256: String, partSize: Int
        let parts: [Part]
    }

    static let dir = GoldenFixtures.fixturesDir.appending(path: "attachments")
    static func fixture() throws -> (Fixture, Data) {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: dir.appending(path: "upload.json")))
        return (fixture, try Data(contentsOf: dir.appending(path: fixture.file)))
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// Noise caps one transport message at 65535 bytes, 16 of them the tag (D21).
    static let noiseMaxPlaintext = 65535 - 16

    func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func photo() throws -> PhotoAttachment {
        let (fixture, data) = try Self.fixture()
        return PhotoAttachment(data: data, mediaType: fixture.mediaType, name: fixture.name, thumbnail: Data([0xFF, 0xD8, 1, 2]))
    }

    func launch(attachments: Bool = true) async throws -> (TaskListStore, FakeHost, String) {
        let fake = FakeHost(script: .init(reply: ["I see ", "a photo."]), hostName: "Photo Mac",
                            extraCapabilities: attachments ? [DSHProtocolInfo.attachmentsCapability] : [])
        let key = "fake:photo"
        let store = TaskListStore(container: try TaskCache.container(inMemory: true), hosts: [
            .init(key: key, connection: HostConnection(endpoint: .localBridge(port: 47801), channel: PlaintextChannel(),
                                                       transport: fake.factory), name: "Photo Mac"),
        ], prompt: "")
        store.sendWaitsFor = .seconds(2)
        store.foreground()
        try await waitUntil("online") { store.hosts.first?.reachability == .online }
        return (store, fake, key)
    }

    @Test func goldenPhotoSplitsIntoTheFixtureParts() throws {
        let (fixture, data) = try Self.fixture()
        #expect(Attachments.partSize == fixture.partSize)
        #expect(data.count == fixture.size)
        #expect(Self.hex(Attachments.sha256(data)) == fixture.sha256)
        let parts = Attachments.parts(of: data)
        #expect(parts.map(\.count) == fixture.parts.map(\.size))
        #expect(parts.map { Self.hex(Attachments.sha256($0)) } == fixture.parts.map(\.sha256))
        #expect(parts.count >= 3, "the photo needs several Noise messages")
    }

    /// Attach the golden photo and send: it goes up in parts, each frame fits one Noise message,
    /// the host gets it byte-identical, the task names it, and the row keeps the thumbnail.
    @Test func photoGoesUpInPartsBeforeTheTaskAndTheRowKeepsItsThumbnail() async throws {
        let (store, fake, _) = try await launch()
        defer { store.background() }
        #expect(store.canAttachPhoto)
        let photo = try photo()
        store.attachPhoto(photo)
        store.prompt = "What is in this photo?"
        let taskKey = try #require(await store.send(), "\(store.sendError ?? "")")
        #expect(store.composerPhoto == nil, "the photo is for this one task")
        #expect(fake.prompts == ["What is in this photo?"])
        let files = try #require(fake.attachments.first)
        #expect(files.count == 1)
        #expect(files.first?.data == photo.data, "byte-identical")
        #expect(files.first?.mediaType == "image/jpeg")
        #expect(fake.uploadFrameSizes.count == Attachments.parts(of: photo.data).count)
        #expect(fake.uploadFrameSizes.allSatisfy { $0 <= Self.noiseMaxPlaintext })
        try await waitUntil("row") { store.task(taskKey) != nil }
        #expect(store.task(taskKey)?.photoThumbnail == photo.thumbnail)
    }

    /// A refused upload (here: the host does not take attachments) sends no task and keeps the photo.
    @Test func refusedUploadSendsNoTaskAndKeepsThePhoto() async throws {
        let (store, fake, _) = try await launch(attachments: false)
        defer { store.background() }
        #expect(!store.canAttachPhoto)
        store.attachPhoto(try photo())
        store.prompt = "What is in this photo?"
        #expect(await store.send() == nil)
        #expect(store.sendError?.contains("upload/unavailable") == true, "\(store.sendError ?? "")")
        #expect(store.composerPhoto != nil)
        #expect(fake.prompts.isEmpty)
    }

    /// The host checks the hash and the parts: a wrong hash or a missing part is refused, and a
    /// task cannot name an upload that is not staged.
    @Test func wrongHashAndMissingPartAreRefused() async throws {
        let fake = FakeHost(extraCapabilities: [DSHProtocolInfo.attachmentsCapability])
        let bridge = try await fake.factory(URL(string: "ws://127.0.0.1:47801/plaintext")!)
        let (fixture, data) = try Self.fixture()
        let parts = Attachments.parts(of: data)
        var nextID: UInt64 = 1
        func send(_ body: Dshm_V1_Request.OneOf_Body) async throws -> Dshm_V1_Response.OneOf_Body? {
            var frame = Dshm_V1_Frame()
            frame.request = .with { $0.id = nextID; $0.body = body }
            nextID += 1
            try await bridge.send(try frame.serializedData())
            let reply = try Dshm_V1_Frame(serializedBytes: try await bridge.receive())
            return reply.response.body
        }
        func code(_ body: Dshm_V1_Response.OneOf_Body?) -> String? {
            if case .error(let e)? = body { return e.code } else { return nil }
        }
        _ = try await send(.hello(.with { $0.protocolVersion = 1 }))
        func begin(_ id: String, hash: Data) async throws {
            let ack = try await send(.uploadBegin(.with {
                $0.uploadID = id; $0.mediaType = fixture.mediaType; $0.name = fixture.name
                $0.size = UInt64(data.count); $0.sha256 = hash
            }))
            #expect(code(ack) == nil)
        }
        var wrong = Attachments.sha256(data)
        wrong[wrong.startIndex] ^= 0xFF
        try await begin("a", hash: wrong)
        for (i, part) in parts.enumerated() { _ = try await send(.uploadChunk(.with { $0.uploadID = "a"; $0.index = UInt32(i); $0.data = part })) }
        #expect(code(try await send(.uploadEnd(.with { $0.uploadID = "a" }))) == "upload/hash-mismatch")

        try await begin("b", hash: Attachments.sha256(data))
        _ = try await send(.uploadChunk(.with { $0.uploadID = "b"; $0.index = 0; $0.data = parts[0] }))
        #expect(code(try await send(.uploadChunk(.with { $0.uploadID = "b"; $0.index = 2; $0.data = parts[2] }))) == "upload/missing-part")

        #expect(code(try await send(.createTask(.with { $0.prompt = "x"; $0.uploadIds = ["a"] }))) == "upload/unknown")
        #expect(fake.prompts.isEmpty)
        await bridge.close()
    }
}
