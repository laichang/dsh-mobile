import DSHCore
import DSHTestSupport
import Testing

@MainActor
@Suite struct TaskStoreTests {
    /// Waits on the store with no polling: `waitForStore` in StoreWait.swift. A short
    /// timeout here is raised to its 30 s, so a busy machine makes the test slower, not red.
    func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await waitForStore("", timeout: max(timeout, .seconds(30)), sourceLocation: sourceLocation, condition)
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
