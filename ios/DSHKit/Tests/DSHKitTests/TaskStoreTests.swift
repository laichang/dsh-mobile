import DSHCore
import DSHTestSupport
import Testing

@MainActor
@Suite struct TaskStoreTests {
    func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func makeStore(_ script: FakeBridge.Script) -> TaskStore {
        let connection = HostConnection(
            endpoint: .localBridge(), channel: PlaintextChannel(), transport: FakeBridge.factory(script: script))
        return TaskStore(connection: connection, prompt: "Introduce yourself.")
    }

    @Test func streamsTaskToCompletionAgainstFakeBridge() async throws {
        let (pause, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        var script = FakeBridge.Script(reply: ["你好", "，", "world"], chunkDelay: .zero)
        script.afterFirstChunk = { for await _ in pause {} }
        let store = makeStore(script)
        #expect(store.canSend)
        let send = Task { await store.send() }
        try await waitUntil { store.transcript == "你好" }
        #expect(store.status.token == "running")
        release.finish()
        await send.value
        try await waitUntil { store.status == .completed }
        #expect(store.transcript == "你好，world")
        #expect(store.status.token == "completed")
        #expect(store.canSend)
    }

    @Test func failedTaskShowsFailure() async throws {
        let store = makeStore(.init(reply: ["partial"], chunkDelay: .milliseconds(5), failWith: "error: rate limited"))
        await store.send()
        try await waitUntil { store.status.token == "failed" }
        #expect(store.status == .failed("error: rate limited"))
        #expect(store.transcript == "partial")
    }

    @Test func emptyPromptCannotBeSent() {
        let store = makeStore(.init())
        store.prompt = "   "
        #expect(!store.canSend)
    }
}
