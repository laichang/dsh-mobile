import DSHProtocol
import Foundation

public typealias ModelSelection = Dshm_V1_ModelSelection
public typealias ModelCatalog = Dshm_V1_ModelCatalog

public extension ModelSelection {
    init(provider: String, model: String, effort: String? = nil) {
        self.init()
        self.provider = provider
        self.model = model
        if let effort { reasoningEffort = effort }
    }

    var transcriptLine: String {
        let route = "\(provider)/\(model)"
        return "\n[Model: \(route)\(hasReasoningEffort ? " · " + reasoningEffort : "")]\n"
    }
}

public extension ModelCatalog {
    func entry(for selection: ModelSelection) -> Dshm_V1_CatalogModel? {
        groups.first { $0.id == selection.provider }?.models.first { $0.id == selection.model }
    }
}
