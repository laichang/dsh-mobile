import DSHCore
import DSHFeatures
import DSHProtocol
import DSHTestSupport
import Foundation
import Testing

/// Attachments: the Swift half of the golden upload. The TS half is
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

    /// Noise caps one transport message at 65535 bytes, 16 of them the tag.
    static let noiseMaxPlaintext = 65535 - 16

    /// Waits on the store with no polling: `waitForStore` in StoreWait.swift. A short
    /// timeout here is raised to its 30 s, so a busy machine makes the test slower, not red.
    func waitUntil(_ what: String, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        await waitForStore(what, timeout: max(timeout, .seconds(30)), sourceLocation: sourceLocation, condition)
    }

    func photo() throws -> FileAttachment {
        let (fixture, data) = try Self.fixture()
        return FileAttachment(data: data, mediaType: fixture.mediaType, name: fixture.name, thumbnail: Data([0xFF, 0xD8, 1, 2]))
    }

    func launch(attachments: Bool = true, followUps: Bool = false) async throws -> (TaskListStore, FakeHost, String) {
        var script = FakeBridge.Script(reply: ["I see ", "a photo."], chunkDelay: .milliseconds(10))
        if followUps { script.followUpReply = ["Read ", "them."] }
        let fake = FakeHost(script: script, hostName: "Photo Mac",
                            extraCapabilities: attachments ? [DSHProtocolInfo.attachmentsCapability] : [])
        let key = "fake:photo"
        let store = TaskListStore(cache: try TaskCache(inMemory: true), hosts: [
            .init(key: key, connection: HostConnection(endpoint: .localBridge(port: 47801), transport: fake.factory), name: "Photo Mac"),
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

    @Test func pickedFilesUsePlatformReadersAndRespectTheLimitBeforeLoadingBytes() throws {
        let (fixture, _) = try Self.fixture()
        let image = try Attachments.file(at: Self.dir.appending(path: fixture.file))
        #expect(image.kind == .image)
        #expect(image.thumbnail?.starts(with: [0xff, 0xd8]) == true)
        #expect(image.data.starts(with: [0xff, 0xd8]))

        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".txt")
        try Self.notes.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Attachments.file(at: url).data == Self.notes.data)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(Attachments.maxBytes + 1))
        try handle.close()
        let refused = try Attachments.file(at: url)
        #expect(refused.isTooLarge)
        #expect(refused.data.isEmpty)
    }

    /// Attach the golden photo and send: it goes up in parts, each frame fits one Noise message,
    /// the host gets it byte-identical, the task names it, and the row keeps the thumbnail.
    @Test func photoGoesUpInPartsBeforeTheTaskAndTheRowKeepsItsThumbnail() async throws {
        let (store, fake, _) = try await launch()
        defer { store.background() }
        #expect(store.canAttach)
        let photo = try photo()
        store.composer.attach(photo)
        store.composer.prompt = "What is in this photo?"
        let taskKey = try #require(await store.send(), "\(store.composer.sendError ?? "")")
        #expect(store.composer.newTaskAttachments.isEmpty, "the photo is for this one task")
        #expect(fake.prompts == ["What is in this photo?"])
        let files = try #require(fake.attachments.first)
        #expect(files.count == 1)
        #expect(files.first?.data == photo.data, "byte-identical")
        #expect(files.first?.mediaType == "image/jpeg")
        #expect(fake.uploadFrameSizes.count == Attachments.parts(of: photo.data).count)
        #expect(fake.uploadFrameSizes.allSatisfy { $0 <= Self.noiseMaxPlaintext })
        try await waitUntil("row") { store.task(taskKey) != nil }
        #expect(store.task(taskKey)?.attachments.map(\.thumbnail) == [photo.thumbnail])
    }

    /// A refused upload (here: the host does not take attachments) sends no task and keeps the photo.
    @Test func refusedUploadSendsNoTaskAndKeepsThePhoto() async throws {
        let (store, fake, _) = try await launch(attachments: false)
        defer { store.background() }
        #expect(!store.canAttach)
        store.composer.attach(try photo())
        store.composer.prompt = "What is in this photo?"
        #expect(await store.send() == nil)
        #expect(store.composer.sendError?.contains(MessageSendError.unavailable.description) == true, "\(store.composer.sendError ?? "")")
        #expect(store.composer.newTaskAttachments.count == 1)
        #expect(fake.prompts.isEmpty)
    }

    /// The host checks the hash and the parts: a wrong hash or a missing part is refused, and a
    /// task cannot name an upload that is not staged.
    @Test func wrongHashAndMissingPartAreRefused() async throws {
        let fake = FakeHost(extraCapabilities: [DSHProtocolInfo.attachmentsCapability])
        let bridge = try await fake.factory(URL(string: "wss://127.0.0.1:47801/")!)
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

    // MARK: - Files of any type, more than one, in follow-ups

    static let notes = FileAttachment(data: Data("Buy milk.\n买牛奶。\n".utf8), mediaType: "text/plain", name: "notes.txt")
    static let report = FileAttachment(data: Data(("%PDF-1.4\n" + String(repeating: "x", count: Attachments.partSize + 10) + "\n%%EOF\n").utf8),
                                   mediaType: "application/pdf", name: "report.pdf")
    static let unknown = FileAttachment(data: Data([0, 1, 2, 3, 254, 255]), mediaType: "application/octet-stream", name: "data.xyz")

    /// A photo, a text file, a PDF and a file of an unknown type, with one removed: the others go
    /// up in their order with their names and types, and the row keeps them for the bubble.
    @Test func filesOfAnyTypeGoUpInOrderAndOneRemovedStaysHome() async throws {
        let (store, fake, _) = try await launch()
        defer { store.background() }
        let photo = try photo()
        for file in [photo, Self.notes, Self.unknown, Self.report] { #expect(store.composer.attach(file)) }
        store.composer.removeAttachment(Self.unknown.id)
        #expect(store.composer.newTaskAttachments.map(\.attachment.name) == ["photo.jpg", "notes.txt", "report.pdf"])
        #expect(store.composer.newTaskAttachments.map(\.attachment.kind) == [.image, .file, .file])
        store.composer.prompt = "Read these."
        let taskKey = try #require(await store.send(), "\(store.composer.sendError ?? "")")
        #expect(store.composer.newTaskAttachments.isEmpty)
        let files = try #require(fake.attachments.first)
        #expect(files.map(\.name) == ["photo.jpg", "notes.txt", "report.pdf"])
        #expect(files.map(\.mediaType) == ["image/jpeg", "text/plain", "application/pdf"])
        #expect(files.map(\.data) == [photo.data, Self.notes.data, Self.report.data], "byte-identical")
        try await waitUntil("row") { store.task(taskKey) != nil }
        let sent = try #require(store.task(taskKey)?.attachments)
        #expect(sent.map(\.name) == ["photo.jpg", "notes.txt", "report.pdf"])
        #expect(sent.map(\.kind) == [.image, .file, .file])
        #expect(sent.map(\.size) == [photo.data.count, Self.notes.data.count, Self.report.data.count])
        #expect(sent.map { $0.thumbnail != nil } == [true, false, false])

        // An unknown type goes too, as a file.
        #expect(store.composer.attach(Self.unknown))
        store.composer.prompt = "And this?"
        #expect(await store.send() != nil, "\(store.composer.sendError ?? "")")
        #expect(fake.attachments.last?.map(\.name) == ["data.xyz"])
    }

    /// A file over the limit is refused on the phone before any upload frame: its chip says so,
    /// the send key stays off, and the host gets nothing. A composer takes at most `maxCount` files.
    @Test func aFileOverTheLimitIsRefusedBeforeTheUpload() async throws {
        let (store, fake, _) = try await launch()
        defer { store.background() }
        let big = FileAttachment(data: Data(count: Attachments.maxBytes + 1), mediaType: "application/pdf", name: "big.pdf")
        #expect(store.composer.attach(big))
        #expect(store.composer.newTaskAttachments.first?.status == .tooLarge)
        store.composer.prompt = "Read this."
        #expect(!store.canSend)
        #expect(await store.send() == nil)
        let connection = HostConnection(endpoint: .localBridge(port: 47801), transport: fake.factory)
        try await connection.connect()
        await #expect(throws: MessageSendError.tooLarge(big.name)) { _ = try await connection.upload(big) }
        await connection.disconnect()
        #expect(fake.uploadBegins == 0, "refused before the upload")
        #expect(fake.prompts.isEmpty)
        store.composer.removeAttachment(big.id)
        #expect(store.canSend)

        for i in 0..<Attachments.maxCount {
            #expect(store.composer.attach(FileAttachment(data: Data([UInt8(i)]), mediaType: "text/plain", name: "\(i).txt")))
        }
        #expect(!store.composer.attach(Self.notes), "at most \(Attachments.maxCount) files in one message")
    }

    @Test func aRejectedOrCancelledBatchLeavesOtherMessagesAndUploadSlotsIntact() async throws {
        let fake = FakeHost(extraCapabilities: [DSHProtocolInfo.attachmentsCapability])
        let connection = HostConnection(endpoint: .localBridge(), transport: fake.factory)
        let link = HostSync(config: .init(key: "test", connection: connection), cache: try TaskCache(inMemory: true))
        let files = Array(repeating: Self.notes, count: Attachments.maxCount)
        let photo = try photo()
        let large = FileAttachment(data: Data(), mediaType: "application/pdf", name: "large", size: Attachments.maxBytes + 1)
        func create(_ text: String, _ files: [FileAttachment]) async throws -> String {
            try await link.createTask(prompt: text, selection: nil, workspace: nil, attachments: files) { _, _ in }
        }
        await #expect(throws: MessageSendError.tooMany) { _ = try await create("too many", files + [photo]) }
        await #expect(throws: MessageSendError.tooLarge("large")) { _ = try await create("too large", [photo, large]) }
        #expect(fake.uploadBegins == 0)

        let cancelled = Task {
            try await link.createTask(prompt: "cancelled", selection: nil, workspace: nil, attachments: [photo]) { _, progress in
                if case .success(let fraction) = progress, fraction > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let kept = try await create("kept", files)
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(fake.prompts == ["kept"])
        #expect(fake.attachments.first?.map(\.name) == files.map(\.name))
        let row = try #require(link.rows(hostName: "Test").first { $0.key == kept })
        let begins = fake.uploadBegins
        await #expect(throws: MessageSendError.tooLarge("large")) {
            try await link.sendFollowUp("too large", for: row, attachments: [photo, large]) { _, _ in }
        }
        #expect(fake.uploadBegins == begins)
        #expect(fake.followUps.isEmpty)
    }

    /// A follow-up in a completed session carries files: they reach the same task on the host, the
    /// user message names them, and the bubble keeps this phone's thumbnail of the photo.
    @Test func aFollowUpCarriesFilesIntoTheSameTask() async throws {
        let (store, fake, _) = try await launch(followUps: true)
        defer { store.background() }
        store.composer.prompt = "Hello."
        let taskKey = try #require(await store.send())
        try await waitUntil("first turn done") { store.task(taskKey)?.state == .completed }
        let done = try #require(store.task(taskKey))
        #expect(store.canAttach(to: done))
        let target = AttachTarget.followUp(taskKey: taskKey)
        let photo = try photo()
        #expect(store.composer.attach(Self.notes, to: target))
        #expect(store.composer.attach(photo, to: target))
        #expect(store.composer.newTaskAttachments.isEmpty, "the page's files are not on composer 01")
        store.composer.sessionDrafts[taskKey] = "And these?"
        try await store.submitDraft(for: done, answering: nil)
        #expect(store.composer.sessionDrafts[taskKey] == nil)
        #expect(store.composer.attachments(on: target).isEmpty)
        #expect(fake.followUps == ["And these?"])
        #expect(fake.followUpAttachments.first?.map(\.name) == ["notes.txt", "photo.jpg"])
        #expect(fake.followUpAttachments.first?.map(\.data) == [Self.notes.data, photo.data])
        try await waitUntil("second turn done") { store.task(taskKey)?.state == .completed && store.task(taskKey)?.blocks.followUpCount == 1 }
        let items = store.task(taskKey)?.blocks.items ?? []
        let message = try #require(items.first { $0.isUserMessage })
        #expect(message.attachments?.map(\.name) == ["notes.txt", "photo.jpg"])
        #expect(message.attachments?.map(\.kind) == [.file, .image])
        #expect(message.attachments?.map { $0.thumbnail != nil } == [false, true], "this phone keeps the photo's thumbnail")
    }
}
