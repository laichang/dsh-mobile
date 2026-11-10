import DSHCore
import DSHProtocol
import DSHTestSupport
import Foundation
import SwiftProtobuf
import Testing

/// The drawer's host › workspace › session tree, its marks, and the local read state.
@MainActor
@Suite(.serialized) struct DrawerTreeTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s14-\(UUID().uuidString).store")

    /// Waits on the store with no polling: `waitForStore` in StoreWait.swift. A short
    /// timeout here is raised to its 30 s, so a busy machine makes the test slower, not red.
    func waitUntil(_ what: String, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        await waitForStore(what, timeout: max(timeout, .seconds(30)), sourceLocation: sourceLocation, condition)
    }

    func store(_ hosts: [TaskListStore.HostConfig]) throws -> TaskListStore {
        let store = TaskListStore(container: try TaskCache.container(url: storeURL), hosts: hosts)
        store.backoff = (.milliseconds(20), .milliseconds(100))
        return store
    }

    func tree(_ store: TaskListStore, _ name: String) throws -> DrawerTree {
        let host = try #require(store.hosts.first { $0.name == name })
        return DrawerTree(rows: store.tasks, hostKey: host.key, capabilities: host.capabilities)
    }

    static func fixture(_ name: String) throws -> Dshm_V1_TaskSummary {
        let bytes = try Data(contentsOf: GoldenFixtures.fixturesDir.appending(path: "\(name).binpb"))
        let frame = try Dshm_V1_Frame(serializedBytes: bytes)
        return frame.event.taskUpserted.task
    }

    /// The Swift half of the drawer golden fixtures: the same frames bridge/test/drawer.test.ts sends.
    @Test func goldenWebAndPhoneSessionsDecodeTheirWorkspace() async throws {
        let phone = try Self.fixture("drawer_phone_session_upserted_event")
        let web = try Self.fixture("drawer_web_session_upserted_event")
        #expect(phone.workspace == "/work/app" && phone.hasWorkspace)
        #expect(web.workspace == "/work/app" && web.externalSession)
        // Through a host, into the cache, into one workspace of the drawer.
        let host = FakeHost(hostName: "Mac", seed: [phone, web], extraCapabilities: [DrawerTree.capability])
        let store = try store([.init(key: "fake:mac", connection: HostConnection(
            endpoint: .localBridge(), channel: PlaintextChannel(), transport: host.factory))])
        store.foreground()
        try await waitUntil("both sessions") { store.tasks.count == 2 }
        #expect(store.tasks.allSatisfy { $0.workspace == "/work/app" })
        let drawer = try tree(store, "Mac")
        #expect(drawer.grouped)
        #expect(drawer.workspaces.map(\.path) == ["/work/app"])
        #expect(drawer.workspaces.first?.sessions.map(\.taskID) == ["web-1", "session-1"])
        #expect(drawer.loose.isEmpty)
    }

    @Test func groupsByHostAndWorkspaceWithTheThreeMarks() async throws {
        let store = try store(FakeDrawer.hosts(.online))
        store.foreground()
        try await waitUntil("six sessions") { store.tasks.count == 6 }
        let mac = try tree(store, FakeDrawer.macName)
        #expect(mac.workspaces.map(\.name) == ["Q3", "dsh-mobile"])
        #expect(mac.workspaces.map(\.displayPath) == ["~/Desktop/Q3", "~/code/dsh-mobile"])
        #expect(mac.workspaces[0].sessions.map(\.title) == ["整理 Q3 报表成 PPT", "Q3 summary slides", "网页第一条"])
        #expect(mac.workspaces[0].sessions.map(\.drawerMark) == [.waiting, .unread, .unread])
        #expect(mac.workspaces[1].sessions.map(\.drawerMark) == [.running])
        let office = try tree(store, FakeDrawer.officeName)
        #expect(office.workspaces.map(\.name) == ["office"])
        #expect(store.sections.waitingOnMe.count == FakeDrawer.waitingCount)
    }

    @Test func readStateStaysInTheCacheUntilTheSessionChanges() async throws {
        var store: TaskListStore? = try store(FakeDrawer.hosts(.online))
        store?.foreground()
        try await waitUntil("six sessions") { store?.tasks.count == 6 }
        let slides = try #require(store?.tasks.first { $0.title == "Q3 summary slides" })
        let running = try #require(store?.tasks.first { $0.state == .running })
        store?.markRead(slides.key)
        store?.markRead(running.key) // A running session has no read mark to clear.
        #expect(store?.task(slides.key)?.drawerMark == .read)
        #expect(store?.task(running.key)?.drawerMark == .running)
        store?.background()
        store = nil

        // Relaunch with the office host offline: the read mark and the office workspace come from the cache.
        let reopened = try self.store(FakeDrawer.hosts(.officeOffline))
        #expect(reopened.task(slides.key)?.drawerMark == .read)
        reopened.foreground()
        let officeKey = try #require(reopened.hosts.first { $0.name == FakeDrawer.officeName }?.key)
        try await waitUntil("office offline") { reopened.hosts.first { $0.key == officeKey }?.reachability == .offline }
        try await waitUntil("mac online") { reopened.hosts.first { $0.name == FakeDrawer.macName }?.reachability == .online }
        #expect(reopened.task(slides.key)?.drawerMark == .read, "the same host state does not mark it unread again")
        let office = try tree(reopened, FakeDrawer.officeName)
        #expect(office.grouped)
        #expect(office.workspaces.first?.sessions.map(\.title) == ["Install the printer driver", "Weekly report"])
    }

    @Test func withoutTheCapabilityTheDrawerShowsHostAndSession() async throws {
        let store = try store(FakeDrawer.hosts(.noCapability))
        store.foreground()
        try await waitUntil("six sessions") { store.tasks.count == 6 }
        try await waitUntil("capabilities") { store.hosts.allSatisfy { !$0.capabilities.isEmpty } }
        let mac = try tree(store, FakeDrawer.macName)
        #expect(!mac.grouped)
        #expect(mac.workspaces.isEmpty)
        #expect(mac.loose.map(\.title) == ["整理 Q3 报表成 PPT", "修复 CI 挂掉的测试并提 PR", "Q3 summary slides", "网页第一条"])
    }

    @Test func homeDirectoriesShowAsTilde() {
        func path(_ p: String) -> String { DrawerTree.Workspace(path: p, sessions: []).displayPath }
        #expect(path("/Users/laichang/Desktop/Q3") == "~/Desktop/Q3")
        #expect(path("/home/me") == "~")
        #expect(path("/work/app") == "/work/app")
        #expect(DrawerTree.Workspace(path: "/", sessions: []).name == "/")
    }
}
