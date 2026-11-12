import DSHCore
import DSHFeatures
import DSHProtocol
import DSHTestSupport
import DSHPlatform
import Foundation
import Testing

@MainActor struct SessionHistoryTests {
    @Test func liveAndOfflineUseTheSameJournalAndAnOlderReadCannotReplaceIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.store")
        let key = CachedTask.key(hostKey: "host", taskID: FakeTurns.taskID)
        var wire = FakeTurns.journal()
        var image = Dshm_V1_AttachmentRef()
        image.kind = .image
        image.name = "chart.png"
        image.mediaType = "image/png"
        image.size = 14
        var file = Dshm_V1_AttachmentRef()
        file.name = "notes.txt"
        wire.messages[0].attachments = [image, file]

        func open(page: Dshm_V1_SessionPage, revision: UInt64) async throws -> TaskListStore {
            var summary = FakeTurns.summary()
            summary.sessionRevision = revision
            let host = FakeHost(seed: [summary], journals: [summary.taskID: page])
            let connection = HostConnection(endpoint: .localBridge(), transport: host.factory)
            let store = TaskListStore(cache: try TaskCache(url: url), hosts: [.init(key: "host", connection: connection)])
            store.foreground()
            await waitForStore("updated session") { store.task(key)?.sessionRevision == revision && store.hosts.first?.reachability == .online }
            return store
        }

        let store = try await open(page: wire, revision: 4)
        let liveRow = try #require(store.task(key))
        let live = try #require(try await store.readHistory(for: liveRow))
        #expect(live.messages.map(\.seq) == [1, 2, 3, 4])
        #expect(live.messages[0].attachments == [
            MessageAttachment(kind: .image, name: "chart.png", size: 14, mediaType: "image/png"),
            MessageAttachment(kind: .file, name: "notes.txt", size: 0)
        ])
        store.background()
        let disconnected = HostConnection(endpoint: .localBridge(), transport: FakeHost().factory)
        let offline = TaskListStore(cache: try TaskCache(url: url), hosts: [.init(key: "host", connection: disconnected)])
        let savedRow = try #require(offline.task(key))
        let saved = try #require(try await offline.readHistory(for: savedRow))
        #expect(saved.messages == live.messages)
        #expect(saved.throughSeq == live.throughSeq)

        wire.throughSeq = 2
        wire.messages = Array(wire.messages.prefix(2))
        let reconnect = try await open(page: wire, revision: 5)
        defer { reconnect.background() }
        let replayRow = try #require(reconnect.task(key))
        let replay = try #require(try await reconnect.readHistory(for: replayRow))
        #expect(replay.messages == live.messages)
        #expect(replay.throughSeq == live.throughSeq)
    }
}
