#if DEBUG
import DSHCore
import DSHProtocol
import Foundation

/// Two FakeBridge hosts with models and workspaces, as on screens 07, M and X4
/// (`-DSHMFakeBridge pickers`). MacBook-Pro is the default host. Its DeepSeek-V41-Pro leaves the
/// catalog once a task uses it, and its OpenRouter list fails.
public enum FakePickers {
    public static let macName = "MacBook-Pro"
    public static let officeName = "Office-PC"
    public static let home = "/Users/laichang"
    public static let q3 = "/Users/laichang/Desktop/Q3"
    public static let repo = "/Users/laichang/code/dsh-mobile"
    public static let analysis = "/Users/laichang/data/analysis"
    public static let officeHome = "/home/laichang"
    public static let officeReports = "/home/laichang/reports"

    public static let provider = "deepseek"
    public static let flash = "deepseek-v41-flash"
    public static let pro = "deepseek-v41-pro"

    /// Office-PC first: with no saved choice, the composer uses the last host (MacBook-Pro).
    public static func hosts(hold: String? = nil) -> [TaskListStore.HostConfig] {
        [(officeName, officePickers), (macName, macPickers)].enumerated().map { index, host in
            let (name, pickers) = host
            var script = FakeBridge.Script(reply: ["Reply ", "from ", name], chunkDelay: .milliseconds(200))
            script.holdPrompt = hold
            let fake = FakeHost(script: script, hostName: name, pickers: pickers)
            let endpoint = HostEndpoint.localBridge(port: 47801 + index)
            return .init(key: "fake:\(name)", connection: HostConnection(endpoint: endpoint, transport: fake.factory), name: name)
        }
    }

    static var macPickers: FakeBridge.Pickers {
        var failure = Dshm_V1_ModelCatalogFailure()
        failure.id = "openrouter"
        failure.name = "OpenRouter"
        failure.message = "无法获取模型列表（密钥无效）"
        var catalog = catalog(failures: [failure])
        catalog.routableProviders = [provider]
        return .init(catalog: catalog, workspaces: .init(defaultPath: home, recentPaths: [q3, repo, analysis]), goneAfterUse: [pro])
    }

    static var officePickers: FakeBridge.Pickers {
        .init(catalog: catalog(failures: []), workspaces: .init(defaultPath: officeHome, recentPaths: [officeReports]))
    }

    static func catalog(failures: [Dshm_V1_ModelCatalogFailure]) -> Dshm_V1_ModelCatalog {
        func effort(_ id: String, _ name: String) -> Dshm_V1_ModelEffort {
            var e = Dshm_V1_ModelEffort()
            e.id = id
            e.name = name
            return e
        }
        func model(_ id: String, _ name: String) -> Dshm_V1_CatalogModel {
            var m = Dshm_V1_CatalogModel()
            m.id = id
            m.name = name
            m.efforts = [effort("low", "Low"), effort("medium", "Medium"), effort("high", "High")]
            m.defaultEffort = "high"
            return m
        }
        var group = Dshm_V1_ModelGroup()
        group.id = provider
        group.name = "DeepSeek"
        group.models = [model(flash, "DeepSeek-V41-Flash"), model(pro, "DeepSeek-V41-Pro")]
        var catalog = Dshm_V1_ModelCatalog()
        catalog.groups = [group]
        catalog.defaultSelection.provider = provider
        catalog.defaultSelection.model = flash
        catalog.defaultSelection.reasoningEffort = "high"
        catalog.failures = failures
        return catalog
    }
}
#endif
