import DSHCore
import DSHTestSupport
import Foundation
import Testing

/// S20 · the model and workspace sheets against the `FakePickers` hosts (PLAN.md §5 S20).
@MainActor
@Suite(.serialized) struct PickerTests {
    /// Waits on the store with no polling (S12): `waitForStore` in StoreWait.swift. A short
    /// timeout here is raised to its 30 s, so a busy machine makes the test slower, not red.
    func waitUntil(_ what: String, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        await waitForStore(what, timeout: max(timeout, .seconds(30)), sourceLocation: sourceLocation, condition)
    }

    func launch(hold: String? = nil) async throws -> (TaskListStore, String) {
        let store = TaskListStore(container: try TaskCache.container(inMemory: true),
                                  hosts: FakePickers.hosts(hold: hold), prompt: "")
        store.sendWaitsFor = .seconds(2)
        let mac = "fake:\(FakePickers.macName)"
        #expect(store.composerHostKey == mac, "with no saved choice, MacBook-Pro is the default host")
        store.foreground()
        try await waitUntil("catalog") { store.catalogs[mac] != nil }
        return (store, mac)
    }

    /// Pick the dsh-mobile workspace and DeepSeek-V41-Pro; the host then loses Pro. The sheet
    /// names Pro, selects nothing in its place, and 应用 stays off until another model is picked.
    @Test func unavailableModelIsNamedAndNothingIsSelectedInItsPlace() async throws {
        let (store, mac) = try await launch(hold: "修复")
        defer { store.background() }
        let pro = ModelSelection(provider: FakePickers.provider, model: FakePickers.pro, effort: "high")
        let flash = ModelSelection(provider: FakePickers.provider, model: FakePickers.flash, effort: "high")
        let catalog = try #require(store.catalogs[mac])
        #expect(catalog.isAvailable(pro))
        #expect(catalog.isHostDefault(provider: FakePickers.provider, model: FakePickers.flash))
        #expect(catalog.failures.map(\.name) == ["OpenRouter"], "a failed provider list is one row")
        #expect(ModelSheetState(catalog: catalog, current: pro).initialDraft == pro)

        let workspaces = try await store.listWorkspaces(hostKey: mac)
        #expect(workspaces.recentPaths.contains(FakePickers.repo))
        store.chooseWorkspace(FakePickers.repo, hostKey: mac)
        store.composerSelections[mac] = pro
        store.prompt = "修复 CI 挂掉的测试"
        let key = try #require(await store.send())
        #expect(store.composerWorkspaces[mac] == nil, "the workspace choice is for this one new session")
        try await waitUntil("task carries Pro") { store.task(key)?.modelSelection == pro }

        await store.refreshCatalog(hostKey: mac)
        let after = try #require(store.catalogs[mac])
        #expect(!after.isAvailable(pro))
        let row = try #require(store.task(key))
        let sheet = ModelSheetState(catalog: after, current: row.modelSelection)
        #expect(sheet.unavailable == pro)
        #expect(sheet.initialDraft == nil, "no other model is selected in its place")
        #expect(!ModelSheetState.canApply(sheet.initialDraft, in: after))
        #expect(!ModelSheetState.canApply(pro, in: after))
        #expect(ModelSheetState.canApply(flash, in: after))
        #expect(after.providerName(FakePickers.provider) == "DeepSeek")

        await #expect(throws: (any Error).self) { try await store.selectModel(pro, for: row) }
        try await store.selectModel(flash, for: row)
        try await waitUntil("task carries Flash") { store.task(key)?.modelSelection == flash }
    }

    @Test func pickersScenarioParses() {
        #expect(DebugLaunchOptions.parse(["-DSHMFakeBridge", "pickers"]).fakePickers)
        #expect(!DebugLaunchOptions.parse(["-DSHMFakeBridge", "YES"]).fakePickers)
    }
}
