@testable import DSHCore
@testable import DSHFeatures
import DSHProtocol
import DSHTestSupport
import Foundation
import SwiftData
import Testing

@MainActor
struct DurableHostSyncTests {
    private func config(_ key: String, _ host: FakeHost) -> TaskListStore.HostConfig {
        .init(key: key, connection: .init(endpoint: .localBridge(), transport: host.factory))
    }

    private func chunk(_ seq: UInt64, _ text: String) -> Dshm_V1_Event {
        var event = Dshm_V1_Event()
        event.assistantChunk.taskID = "shared"
        event.assistantChunk.seq = seq
        event.assistantChunk.text = text
        return event
    }

    private func cursor(_ url: URL, _ key: String) throws -> Int64? {
        let context = ModelContext(try TaskCache.container(url: url))
        return try context.fetch(FetchDescriptor<CachedHost>(predicate: #Predicate { $0.key == key })).first?.lastSeq
    }

    private func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < end else {
                Issue.record("timed out waiting for host sync", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func failedBatchReplaysFromDiskAndOtherHostCanStillCommit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cache.store")
        let container = try TaskCache.container(url: url)
        let first = FakeHost(extraCapabilities: ["approvals.v1", "transcript.v1"])
        let second = FakeHost()
        var interrupt = false
        var rejected = 0
        let a = HostSync(config: config("a", first), container: container) { context in
            if interrupt {
                rejected += 1
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try context.save()
        }
        let b = HostSync(config: config("b", second), container: container)
        let backoff: (Duration, Duration) = (.milliseconds(20), .milliseconds(50))
        for link in [a, b] { link.start(firstConnectDelay: .zero, backoff: backoff) }
        try await until { a.reachability == .online && b.reachability == .online }
        first.emit(chunk(1, "one"), taskID: "shared")
        try await until { (try? cursor(url, "a")) == 1 }

        interrupt = true
        first.emit(chunk(2, " two"), taskID: "shared")
        var decision = Dshm_V1_Event()
        decision.approvalPending.taskID = "shared"
        decision.approvalPending.id = "decision"
        decision.approvalPending.tool = "read"
        first.emit(decision, taskID: "shared")
        var followup = Dshm_V1_Event()
        followup.userMessage.taskID = "shared"
        followup.userMessage.messageID = "followup"
        followup.userMessage.text = "inspect"
        var file = Dshm_V1_AttachmentRef()
        file.name = "summary.txt"
        file.size = 12
        followup.userMessage.attachments = [file]
        first.emit(followup, taskID: "shared")
        second.emit(chunk(1, "other host"), taskID: "shared")
        try await until { rejected > 0 && (try? cursor(url, "b")) == 1 }
        a.retire()
        b.retire()
        try await until { first.connectionCount == 0 && second.connectionCount == 0 }

        func launch() throws -> TaskListStore {
            TaskListStore(cache: try TaskCache(url: url), hosts: [config("a", first), config("b", second)])
        }
        let store = try launch()
        let key = CachedTask.key(hostKey: "a", taskID: "shared")
        let other = CachedTask.key(hostKey: "b", taskID: "shared")
        #expect(try cursor(url, "a") == 1)
        #expect(store.task(key)?.transcript == "one")
        #expect(store.task(key)?.approvals.isEmpty == true)
        #expect(store.task(other)?.transcript == "other host")

        store.foreground()
        store.background()
        store.foreground()
        store.foreground()
        await waitForStore("replayed pending message") { store.task(key)?.blocks.items.last?.attachments?.first?.name == "summary.txt" }
        store.background()
        let offline = try launch()
        let row = try #require(offline.task(key))
        #expect(try cursor(url, "a") == Int64(first.head))
        #expect(row.transcript == "one two")
        #expect(row.approvals.map(\.id) == ["decision"])
        #expect(row.blocks.items.compactMap(\.attachments).flatMap { $0 }.map(\.size) == [12])
        #expect(offline.task(other)?.transcript == "other host")
    }

    @Test func restartFinishesListingAfterPersistingALogReset() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cache.store")
        let original = FakeHost()
        let replacement = FakeHost()
        let store = TaskListStore(cache: try TaskCache(url: url), hosts: [config("a", original)])
        store.foreground()
        await waitForStore("online") { store.hosts.first?.reachability == .online }
        original.emit(chunk(1, "unfinished"), taskID: "shared")
        let key = CachedTask.key(hostKey: "a", taskID: "shared")
        await waitForStore("old host task") { store.task(key)?.transcript == "unfinished" }

        // Persist the reset in the interval before ListTasks returns.
        var reset = Dshm_V1_Event()
        reset.logReset.logID = replacement.logID
        original.emit(reset, taskID: "")
        try await until {
            guard let database = try? TaskCache.container(url: url) else { return false }
            return (try? ModelContext(database).fetch(FetchDescriptor<CachedHost>()).first?.logID) == replacement.logID
        }
        store.background()
        let reopened = TaskListStore(cache: try TaskCache(url: url), hosts: [config("a", replacement)])
        reopened.foreground()
        defer { reopened.background() }
        await waitForStore("resume on the already saved log ID") { reopened.hosts.first?.reachability == .online }
        #expect(reopened.task(key)?.state == .failed)
    }
}
