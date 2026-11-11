import DSHCore
import DSHFeatures
import DSHProtocol
import DSHTestSupport
import Foundation
import SwiftData
import Testing

struct ModelDomainTests {
    @MainActor
    @Test(arguments: [nil, "", "high"] as [String?])
    func reopensLegacySelectionPreservingEffort(_ effort: String?) throws {
        let container = try TaskCache.container(inMemory: true)
        let context = ModelContext(container)
        let task = CachedTask(hostKey: "mac", taskID: "task", title: "Session", createdAt: .now)
        var selection = Dshm_V1_ModelSelection()
        selection.provider = "mock"
        selection.model = "alpha"
        if let effort { selection.reasoningEffort = effort }
        task.modelSelectionData = try selection.serializedData()
        context.insert(task)
        try context.save()

        let connection = HostConnection(endpoint: .localBridge(), transport: FakeHost().factory)
        let reopened = TaskListStore(cache: TaskCache(container), hosts: [.init(key: "mac", connection: connection)])
        #expect(reopened.task(task.key)?.modelSelection == ModelSelection(provider: "mock", model: "alpha", effort: effort))
    }

    @Test func catalogPreservesHostOrderAndAbsentDefaults() async throws {
        var first = Dshm_V1_ModelGroup()
        first.id = "z"
        var model = Dshm_V1_CatalogModel()
        model.id = "m"
        first.models = [model]
        var second = Dshm_V1_ModelGroup()
        second.id = "a"
        var wire = Dshm_V1_ModelCatalog()
        wire.groups = [first, second]
        let host = FakeHost(pickers: .init(catalog: wire, workspaces: .init(defaultPath: "/", recentPaths: [])))
        let connection = HostConnection(endpoint: .localBridge(), transport: host.factory)
        try await connection.connect()
        let catalog = try await connection.modelCatalog()
        await connection.disconnect()

        #expect(catalog.groups.map(\.id) == ["z", "a"])
        #expect(catalog.defaultSelection == nil)
        let entry = try #require(catalog.entry(for: .init(provider: "z", model: "m")))
        #expect(entry.defaultEffort == nil)
    }
}
