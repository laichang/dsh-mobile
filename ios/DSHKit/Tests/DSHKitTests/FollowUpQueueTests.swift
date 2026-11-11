import DSHCore
import DSHProtocol
import DSHTestSupport
import Foundation
import Testing

/// Follow-ups while a task runs, against `FakeHost` (`conversation.v2`): a follow-up waits
/// in the queue and runs as the next turn; "立即发送" moves it into the running turn; remove takes
/// it out; the queue stays the same after a reconnect; after a stop, a new message continues.
@MainActor
@Suite(.serialized) struct FollowUpQueueTests {
    static let first = ["First ", "answer", " in", " a", " few", " parts", "."]
    static let second = ["Second ", "answer."]

    /// - Parameter pause: with one, the first turn stops after its first chunk until the stream
    ///   finishes, so the follow-ups reach the host before that turn ends, however busy the
    ///   machine (under load the turn ended first).
    func host(chunkDelay: Duration = .milliseconds(120), pause: AsyncStream<Void>? = nil) -> FakeHost {
        var script = FakeBridge.Script(reply: Self.first, chunkDelay: chunkDelay)
        if let pause {
            let release = Task { for await _ in pause {} }
            script.afterFirstChunk = { await release.value }
        }
        script.followUpReply = Self.second
        script.queuesFollowUps = true
        script.interruptible = true
        return FakeHost(script: script)
    }

    func launch(_ host: FakeHost) throws -> TaskListStore {
        try FollowUpTests().launch(host, url: FollowUpTests.cacheURL())
    }

    static func queue(_ row: TaskListStore.TaskRow?) -> [String] {
        (row?.queue ?? []).map { "\($0.text) (\($0.placement.rawValue))" }
    }

    @Test func aFollowUpWhileTheTaskRunsWaitsAndRunsAsTheNextTurn() async throws {
        let (pause, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let host = host(pause: pause)
        let store = try launch(host)
        store.foreground()
        defer { store.background() }
        let key = try #require(await store.send())
        await waitForStore("running") { store.task(key)?.state == .running }
        let running = try #require(store.task(key))
        #expect(store.canFollowUp(running))

        try await store.sendFollowUp("Then this.", for: running)
        await waitForStore("queued") { Self.queue(store.task(key)) == ["Then this. (queued)"] }
        // It waits above the composer; the transcript does not have it yet.
        #expect(try #require(store.task(key)).blocks.followUpCount == 0)
        #expect(store.task(key)?.state == .running)

        release.finish()
        await waitForStore("done") { store.task(key)?.state == .completed }
        let row = try #require(store.task(key))
        #expect(FollowUpTests.page(row) == ["agent: First answer in a few parts.", "user: Then this.", "agent: Second answer."])
        #expect(row.queue.isEmpty)
    }

    @Test func sendNowMovesAQueuedMessageIntoTheTurnAndRemoveTakesOneOut() async throws {
        let (pause, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let host = host(pause: pause)
        let store = try launch(host)
        store.foreground()
        defer { store.background() }
        let key = try #require(await store.send())
        await waitForStore("first chunk") { store.task(key)?.transcript == "First " }
        try await store.sendFollowUp("Not this.", for: try #require(store.task(key)))
        try await store.sendFollowUp("Now this.", for: try #require(store.task(key)))
        await waitForStore("both queued") { Self.queue(store.task(key)) == ["Not this. (queued)", "Now this. (queued)"] }

        let row = try #require(store.task(key))
        try await store.sendNow(row.queue[1], for: row)
        try await store.removeQueued(row.queue[0], for: row)
        // Sent now, it leaves the queue for the transcript at once, where the user sent it.
        await waitForStore("edited") { Self.queue(store.task(key)).isEmpty && store.task(key)?.blocks.followUpCount == 1 }
        #expect(host.queueEdits == ["steer Now this.", "remove Not this."])

        release.finish()
        await waitForStore("done") { store.task(key)?.state == .completed }
        let done = try #require(store.task(key))
        #expect(FollowUpTests.page(done) == ["agent: First ", "user: Now this.", "agent: answer in a few parts.Second answer."])
        #expect(done.queue.isEmpty)
    }

    /// The reported bug: "立即发送" while the agent is in a long step (real DSH gives a steered
    /// message to the agent only when the step ends; here the first turn waits after its first
    /// chunk). The message must show in the transcript at once, not float above the field, and
    /// keep its place when DSH takes it.
    @Test func sendNowDuringALongStepShowsTheMessageInTheTranscriptAtOnce() async throws {
        let (pause, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let host = host(pause: pause)
        let store = try launch(host)
        store.foreground()
        defer { store.background() }
        let key = try #require(await store.send())
        await waitForStore("first chunk") { store.task(key)?.transcript == "First " }
        try await store.sendFollowUp("不用了", for: try #require(store.task(key)))
        await waitForStore("queued") { Self.queue(store.task(key)) == ["不用了 (queued)"] }

        try await store.sendNow(try #require(store.task(key)?.queue.first), for: try #require(store.task(key)))
        await waitForStore("in the transcript") { store.task(key)?.blocks.followUpCount == 1 }
        let sent = try #require(store.task(key))
        #expect(sent.queue.isEmpty, "nothing floats above the field")
        let bubble = try #require(sent.blocks.items.first { $0.isUserMessage })
        #expect(bubble.state == .running, "marked until DSH gives it to the agent")
        #expect(FollowUpTests.page(sent) == ["agent: First ", "user: 不用了"])

        release.finish()
        await waitForStore("done") { store.task(key)?.state == .completed }
        let done = try #require(store.task(key))
        #expect(done.queue.isEmpty)
        #expect(done.blocks.items.filter(\.isUserMessage).map(\.state) == [.done], "DSH took it: one bubble, not marked")
        #expect(FollowUpTests.page(done) == ["agent: First ", "user: 不用了", "agent: answer in a few parts.Second answer."])

        // A reconnect (or another phone) replays the same page.
        let fresh = try launch(host)
        fresh.foreground()
        defer { fresh.background() }
        await waitForStore("replayed") { fresh.task(key).map(FollowUpTests.page) == FollowUpTests.page(done) }
        let replayed = FollowUpTests.page(try #require(fresh.task(key)))
        #expect(replayed == FollowUpTests.page(done), "\(replayed)")
        #expect(fresh.task(key)?.queue.isEmpty == true)
    }

    /// A stop before DSH took a message sent now takes it out of the transcript, and its
    /// text goes back to the composer, as for a queued one.
    @Test func aStopBeforeDSHTookAMessageSentNowGivesItBack() async throws {
        let (pause, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let host = host(pause: pause)
        let store = try launch(host)
        store.foreground()
        defer { store.background() }
        let key = try #require(await store.send())
        await waitForStore("first chunk") { store.task(key)?.transcript == "First " }
        try await store.sendFollowUp("Stop here.", for: try #require(store.task(key)))
        await waitForStore("queued") { store.task(key)?.queue.count == 1 }
        try await store.sendNow(try #require(store.task(key)?.queue.first), for: try #require(store.task(key)))
        await waitForStore("sent now") { store.task(key)?.blocks.followUpCount == 1 }

        try await store.interrupt(try #require(store.task(key)))
        await waitForStore("stopped") { store.task(key)?.state == .interrupted }
        #expect(store.task(key)?.blocks.followUpCount == 0)
        #expect(store.task(key)?.queue.isEmpty == true)
        #expect(store.takeReturnedDrafts(for: key) == ["Stop here."])
    }

    @Test func theQueueAndItsOrderStayTheSameAfterAReconnect() async throws {
        let host = host(chunkDelay: .milliseconds(250))
        let store = try launch(host)
        store.foreground()
        let key = try #require(await store.send())
        await waitForStore("running") { store.task(key)?.state == .running }
        for text in ["One.", "Two.", "Three."] { try await store.sendFollowUp(text, for: try #require(store.task(key))) }
        await waitForStore("queued") { store.task(key)?.queue.count == 3 }
        let middle = try #require(store.task(key)?.queue[1])
        try await store.removeQueued(middle, for: try #require(store.task(key)))
        await waitForStore("removed") { Self.queue(store.task(key)) == ["One. (queued)", "Three. (queued)"] }
        store.background()

        // Another phone, or this one with its cache gone: the log replays the same queue, in order.
        let fresh = try launch(host)
        fresh.foreground()
        defer { fresh.background() }
        await waitForStore("replayed") { Self.queue(fresh.task(key)) == ["One. (queued)", "Three. (queued)"] }
        #expect(fresh.task(key)?.state == .running)
        await waitForStore("done") { fresh.task(key)?.state == .completed }
        #expect(FollowUpTests.page(try #require(fresh.task(key))) == [
            "agent: First answer in a few parts.", "user: One.", "agent: Second answer.", "user: Three.", "agent: Second answer.",
        ])
    }

    @Test func aStopGivesWaitingMessagesBackAndANewMessageContinuesTheTask() async throws {
        let (pause, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let host = host(pause: pause)
        let store = try launch(host)
        store.foreground()
        defer { store.background() }
        let key = try #require(await store.send())
        await waitForStore("first chunk") { store.task(key)?.transcript == "First " }
        try await store.sendFollowUp("Waiting.", for: try #require(store.task(key)))
        await waitForStore("queued") { store.task(key)?.queue.count == 1 }

        try await store.interrupt(try #require(store.task(key)))
        await waitForStore("stopped") { store.task(key)?.state == .interrupted }
        #expect(store.task(key)?.queue.isEmpty == true)
        #expect(store.takeReturnedDrafts(for: key) == ["Waiting."])
        #expect(store.takeReturnedDrafts(for: key).isEmpty, "taken once")

        let stopped = try #require(store.task(key))
        #expect(store.canFollowUp(stopped))
        try await store.sendFollowUp("Go on.", for: stopped)
        await waitForStore("running again") { store.task(key)?.state == .running }
        release.finish()
        await waitForStore("done") { store.task(key)?.state == .completed }
        let page = FollowUpTests.page(try #require(store.task(key)))
        #expect(page.suffix(2) == ["user: Go on.", "agent: Second answer."], "\(page)")
    }

    @Test func aFailedTaskTakesNoFollowUpFromABridgeWithoutFailuresV1() async throws {
        var script = FakeBridge.Script(reply: ["Oops."], chunkDelay: .milliseconds(10), failWith: "error: rate limited")
        script.followUpReply = Self.second
        script.queuesFollowUps = true
        script.reportsFailures = false // A failed task's follow-up needs `failures.v1`
        let store = try launch(FakeHost(script: script))
        store.foreground()
        defer { store.background() }
        let key = try #require(await store.send())
        await waitForStore("failed") { store.task(key)?.state == .failed }
        #expect(!store.canFollowUp(try #require(store.task(key))))
    }
}
