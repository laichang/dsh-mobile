import DSHProtocol
import Foundation

/// The rules of the model sheet (screens M and X4, STORY §8): the user picks the model, and
/// the app never swaps it silently. A selection the host can no longer run is named, nothing else
/// is selected in its place, and 应用 stays off until the user picks a model that is available.
public extension ModelCatalog {
    /// True when the host lists this model, and (if the selection names one) its effort.
    func isAvailable(_ selection: ModelSelection) -> Bool {
        guard let model = entry(for: selection) else { return false }
        return !selection.hasReasoningEffort || model.efforts.contains { $0.id == selection.reasoningEffort }
    }

    /// The host default: the model the host uses when the phone sends no selection.
    func isHostDefault(provider: String, model: String) -> Bool {
        hasDefaultSelection && defaultSelection.provider == provider && defaultSelection.model == model
    }

    /// The display name of a provider; the id when the host does not list it any more.
    func providerName(_ id: String) -> String {
        groups.first { $0.id == id }?.name ?? failures.first { $0.id == id }?.name ?? id
    }
}

/// What the model sheet shows for one host: the current selection, and whether it went away.
public struct ModelSheetState: Equatable, Sendable {
    /// The selection of the task (or the composer) when the sheet opened.
    public var current: ModelSelection?
    /// `current`, when the host can no longer run it. The sheet names it and selects nothing.
    public var unavailable: ModelSelection?

    public init(catalog: ModelCatalog?, current: ModelSelection?) {
        self.current = current
        if let catalog, let current, !catalog.isAvailable(current) { unavailable = current }
    }

    /// The draft the sheet starts with: the current selection, or nothing when it went away.
    public var initialDraft: ModelSelection? { unavailable == nil ? current : nil }

    /// 应用 is on only for a draft the host can run.
    public static func canApply(_ draft: ModelSelection?, in catalog: ModelCatalog?) -> Bool {
        guard let draft, let catalog else { return false }
        return catalog.isAvailable(draft)
    }
}
