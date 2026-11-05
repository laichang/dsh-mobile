import DSHCore
import DSHTestSupport
import Foundation
import SwiftData
import Testing

/// S2 · durable list + resume against `FakeHost` (PLAN.md §5).
@MainActor
@Suite(.serialized) struct TaskListStoreTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s2-\(UUID().uuidString).store")

    func waitUntil(_ what: String = "", timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A store as the app builds it on launch: the cache on disk, one host, nothing running yet.
    func launch(_ host: FakeHost, prompt: String = "Count to five.") throws -> TaskListStore {
        let connection = HostConnection(endpoint: .localBridge(), channel: PlaintextChannel(), transport: host.factory)
        let store = TaskListStore(
            container: try TaskCache.container(url: storeURL),
            hosts: [.init(key: "fake:127.0.0.1:47801", connection: connection)], prompt: prompt)
        store.backoff = (.milliseconds(20), .milliseconds(100))
        store.sendWaitsFor = .milliseconds(500)
        return store
    }

    static let reply = ["one ", "two ", "three ", "four ", "five"]
    static let fullReply = reply.joined()

    @Test func streamsATaskIntoTheUnifiedList() async throws {
        let host = FakeHost(script: .init(reply: Self.reply, chunkDelay: .milliseconds(10)))
        let store = try launch(host)
        store.foreground()
        let key = try #require(await store.send())
        #expect(store.prompt.isEmpty)
        try await waitUntil("completed") { store.task(key)?.state == .completed }
        let task = try #require(store.task(key))
        #expect(task.title == "Count to five.")
        #expect(task.transcript == Self.fullReply)
        #expect(task.hostName == "FakeBridge Mac")
        #expect(store.sections.done.map(\.key) == [key])
        #expect(store.sections.running.isEmpty)
        #expect(store.hosts.map(\.reachability) == [.online])
    }

    @Test func killAndReopenKeepsTheListAndFillsTheGapFromTheBridge() async throws {
        let host = FakeHost(script: .init(reply: Self.reply, chunkDelay: .milliseconds(60)))
        var store: TaskListStore? = try launch(host)
        store?.foreground()
        let key = try #require(await store?.send())
        try await waitUntil("some text") { !(store?.task(key)?.transcript.isEmpty ?? true) }
        // The user swipes the app away: iOS backgrounds it, then it's gone.
        store?.background()
        store = nil
        try await Task.sleep(for: .milliseconds(500)) // the task finishes on the host meanwhile

        let reopened = try launch(host)
        // Before any connection: the list and the transcript so far come from the cache.
        let cached = try #require(reopened.task(key))
        #expect(cached.title == "Count to five.")
        #expect(cached.state == .running)
        #expect(!cached.transcript.isEmpty && cached.transcript != Self.fullReply)
        #expect(Self.fullReply.hasPrefix(cached.transcript))

        reopened.foreground()
        try await waitUntil("gap filled") { reopened.task(key)?.state == .completed }
        // The gap came from the bridge, exactly once: no repeated or missing text.
        #expect(reopened.task(key)?.transcript == Self.fullReply)
        #expect(reopened.sections.done.map(\.key) == [key])
    }

    @Test func reconnectsAfterTheConnectionDropsAndReplaysOnlyTheGap() async throws {
        let host = FakeHost(script: .init(reply: Self.reply, chunkDelay: .milliseconds(40)))
        let store = try launch(host)
        store.foreground()
        let key = try #require(await store.send())
        try await waitUntil("some text") { !(store.task(key)?.transcript.isEmpty ?? true) }
        host.dropConnections()
        try await waitUntil("reconnected") { store.hosts.first?.reachability == .online && host.connectionCount == 1 }
        try await waitUntil("completed") { store.task(key)?.state == .completed }
        #expect(store.task(key)?.transcript == Self.fullReply)
    }

    @Test func explicitModelRequiresUserChoiceWhenReconnectedHostLacksModelSupport() async throws {
        let store = try launch(FakeHost())
        let key = try #require(store.composerHostKey)
        let choice = ModelSelection(provider: "previous-host-provider", model: "previous-model", effort: nil)
        store.composerSelections[key] = choice
        store.foreground()
        defer { store.background() }
        try await waitUntil("reconnected") { store.hosts.first?.reachability == .online }
        #expect(!store.modelHosts.contains(key))
        #expect(await store.send() == nil)
        #expect(store.tasks.isEmpty)
        #expect(store.composerSelections[key] == choice)
        store.useHostDefault(hostKey: key)
        #expect(store.sendError == nil)
        #expect(await store.send() != nil)
    }

    @Test func explicitWorkspaceCannotFallBackAfterBridgeDowngrade() async throws {
        let store = try launch(FakeHost())
        let key = try #require(store.composerHostKey)
        store.chooseWorkspace("/repo/chosen", hostKey: key)
        store.foreground()
        defer { store.background() }
        try await waitUntil("online") { store.hosts.first?.reachability == .online }
        #expect(await store.send() == nil)
        #expect(store.tasks.isEmpty)
        #expect(store.composerWorkspaces[key] == "/repo/chosen")
        #expect(store.sendError?.contains("workspace") == true)
        store.chooseWorkspace(nil, hostKey: key)
        #expect(await store.send() != nil)
    }

    @Test func cachedTasksAppearOnlyForConfiguredHostsEvenWhenOffline() async throws {
        let container = try TaskCache.container(inMemory: true)
        let context = ModelContext(container)
        for host in ["old-loopback", "paired-mac"] {
            let row = CachedTask(hostKey: host, taskID: "same-id", title: host, createdAt: .now)
            if host == "old-loopback" { row.approvalOnly = true }
            context.insert(row)
        }
        try context.save()
        let link = HostConnection(endpoint: .localBridge(), channel: PlaintextChannel(),
                                  transport: FakeHost(reachable: false).factory)
        let store = TaskListStore(container: container, hosts: [.init(key: "paired-mac", connection: link, name: "Paired Mac")])
        store.foreground()
        defer { store.background() }
        try await waitUntil { store.hosts.first?.reachability == .offline }
        #expect(store.offlineHosts.map(\.name) == ["Paired Mac"])
        #expect(store.tasks.map(\.title) == ["paired-mac"])
    }

    @Test func hostsWithTheSameNameRemainDistinguishable() throws {
        let links = [47801, 47802].map { port in
            let endpoint = HostEndpoint.localBridge(port: port)
            let connection = HostConnection(endpoint: endpoint, channel: PlaintextChannel(), transport: FakeHost().factory)
            return TaskListStore.HostConfig(key: endpoint.description, connection: connection, name: "Mac")
        }
        let store = TaskListStore(container: try TaskCache.container(inMemory: true), hosts: links)
        #expect(store.hosts.map(\.name) == ["Mac (127.0.0.1:47801)", "Mac (127.0.0.1:47802)"])
    }

    @Test func composerChoicesStayWithTheirHost() async throws {
        let home = FakeHost(), office = FakeHost()
        let store = TaskListStore(container: try TaskCache.container(inMemory: true), hosts: [
            .init(key: "home", connection: .init(endpoint: .localBridge(), channel: PlaintextChannel(), transport: home.factory)),
            .init(key: "office", connection: .init(endpoint: .localBridge(), channel: PlaintextChannel(), transport: office.factory))
        ], prompt: "Run on office", preferredHostKey: "home")
        store.foreground()
        defer { store.background() }
        let selection = ModelSelection(provider: "home-provider", model: "home-model", effort: nil)
        store.composerSelections["home"] = selection
        store.chooseWorkspace("/home/project", hostKey: "home")
        store.chooseHost("office")
        #expect(await store.send() != nil)
        #expect(office.prompts == ["Run on office"])
        store.chooseHost("home")
        #expect(store.composerSelections["home"] == selection)
        #expect(store.composerWorkspaces["home"] == "/home/project")
        store.prompt = "Requires the chosen model and workspace"
        #expect(await store.send() == nil)
        #expect(home.prompts.isEmpty)
    }

    @Test func unsupportedHostRetainsDraftAndChoicesWhileAnotherHostDispatches() async throws {
        let home = FakeHost(hostName: "Home Mac")
        let office = FakeHost(hostName: "Office Mac", incompatibleDsh: ("0.2.2-alpha.3", "0.2.2-rc.1"))
        let store = TaskListStore(container: try TaskCache.container(inMemory: true), hosts: [
            .init(key: "home", connection: .init(endpoint: .localBridge(), channel: PlaintextChannel(), transport: home.factory), name: home.hostName),
            .init(key: "office", connection: .init(endpoint: .localBridge(), channel: PlaintextChannel(), transport: office.factory), name: office.hostName)
        ], prompt: "Use this repo", preferredHostKey: "office")
        let selection = ModelSelection(provider: "office", model: "office-model", effort: nil)
        store.composerSelections["office"] = selection
        store.chooseWorkspace("/office/repo", hostKey: "office")
        store.foreground()
        defer { store.background() }
        try await waitUntil {
            store.hosts.first { $0.key == "home" }?.reachability == .online
                && store.hosts.first { $0.key == "office" }?.reachability == .needsBridgeUpdate(version: "0.2.2-alpha.3", supported: "0.2.2-rc.1")
        }
        #expect(await store.send() == nil)
        #expect(store.sendError?.contains("Office Mac needs a bridge update") == true)
        #expect(store.prompt == "Use this repo")
        #expect(office.prompts.isEmpty && home.prompts.isEmpty)
        store.chooseHost("home")
        #expect(await store.send() != nil)
        #expect(home.prompts == ["Use this repo"])
        #expect(office.prompts.isEmpty)
        #expect(store.composerSelections["office"] == selection)
        #expect(store.composerWorkspaces["office"] == "/office/repo")
    }

    @Test func offlineSelectionNeverSendsToAnotherHost() async throws {
        let home = FakeHost(hostName: "Home Mac"), office = FakeHost(reachable: false)
        func config(_ key: String, name: String, host: FakeHost) -> TaskListStore.HostConfig {
            .init(key: key, connection: HostConnection(endpoint: .localBridge(), channel: PlaintextChannel(),
                                                       transport: host.factory), name: name)
        }
        let store = TaskListStore(container: try TaskCache.container(inMemory: true),
                                  hosts: [config("home", name: "Home Mac", host: home),
                                          config("office", name: "Office Mac", host: office)],
                                  prompt: "Selected host only", preferredHostKey: "office")
        store.sendWaitsFor = .milliseconds(150)
        store.foreground()
        defer { store.background() }
        try await waitUntil { store.hosts.first?.reachability == .online && store.offlineHosts.count == 1 }
        #expect(await store.send() == nil)
        #expect(store.sendError?.contains("Office Mac") == true)
        #expect(home.prompts.isEmpty)
        home.setReachable(false)
        try await waitUntil { store.offlineHosts.count == 2 }
        #expect(Set(store.offlineHosts.map(\.name)) == ["Home Mac", "Office Mac"])
    }

    @Test func unreachableHostIsNamedAsOffline() async throws {
        let host = FakeHost(script: .init(reply: ["ok"], chunkDelay: .milliseconds(5)))
        let store = try launch(host)
        store.foreground()
        try await waitUntil("online") { store.hosts.first?.reachability == .online }
        host.setReachable(false)
        try await waitUntil("offline") { store.hosts.first?.reachability == .offline }
        #expect(store.offlineHosts.map(\.name) == ["FakeBridge Mac"])
        #expect(await store.send() == nil)
        #expect(store.sendError?.contains("FakeBridge Mac is offline") == true)

        host.setReachable(true)
        store.foreground() // coming back to the foreground retries at once
        try await waitUntil("online again") { store.hosts.first?.reachability == .online }
        #expect(store.offlineHosts.isEmpty)
    }

    @Test func neverReachedHostIsNamedByItsAddress() async throws {
        let store = try launch(FakeHost(reachable: false))
        store.foreground()
        try await waitUntil("offline") { store.hosts.first?.reachability == .offline }
        #expect(store.offlineHosts.map(\.name) == ["127.0.0.1:47801"])
    }

    @Test func bridgeRestartMarksTasksItLostAsFailed() async throws {
        let host = FakeHost(script: .init(reply: Self.reply, chunkDelay: .milliseconds(80)))
        let store = try launch(host)
        store.foreground()
        let key = try #require(await store.send())
        try await waitUntil("some text") { !(store.task(key)?.transcript.isEmpty ?? true) }
        host.restart()
        try await waitUntil("lost") { store.task(key)?.state == .failed }
        #expect(store.task(key)?.message.contains("restarted") == true)
        // The new bridge's tasks still arrive.
        store.prompt = "again"
        let next = try #require(await store.send())
        try await waitUntil("completed") { store.task(next)?.state == .completed }
        #expect(store.task(next)?.transcript == Self.fullReply)
    }
}
