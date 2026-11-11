/// The rules of the model sheet (screens M and X4, STORY §8): the user picks the model, and
/// the app never swaps it silently. A selection the host can no longer run is named, nothing else
/// is selected in its place, and 应用 stays off until the user picks a model that is available.
public extension ModelCatalog {
    /// True when the host lists this model, and (if the selection names one) its effort.
    func isAvailable(_ selection: ModelSelection) -> Bool {
        guard let model = entry(for: selection) else { return false }
        guard let effort = selection.reasoningEffort else { return true }
        return model.efforts.contains { $0.id == effort }
    }

    /// The host default: the model the host uses when the phone sends no selection.
    func isHostDefault(provider: String, model: String) -> Bool {
        defaultSelection?.provider == provider && defaultSelection?.model == model
    }

    /// The display name of a provider; the id when the host does not list it any more.
    func providerName(_ id: String) -> String {
        groups.first { $0.id == id }?.name ?? failures.first { $0.id == id }?.name ?? id
    }
}
