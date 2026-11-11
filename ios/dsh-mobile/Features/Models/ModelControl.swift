import DSHCore
import SwiftUI

/// The model pill (screen 01): the composer's choice, or a running task's.
/// It opens `ModelPicker` as a sheet (`SheetRoute.model`).
struct ModelControl: View {
    let store: TaskListStore
    let hostKey: String
    let task: TaskListStore.TaskRow?
    @Environment(ShellModel.self) private var shell

    private var catalog: ModelCatalog? { store.catalogs[hostKey] }
    private var selection: ModelSelection? {
        if let task { return task.modelSelection }
        return store.composerSelections[hostKey] ?? catalog?.defaultSelection
    }

    var body: some View {
        Button {
            shell.present(.model(hostKey: hostKey, taskKey: task?.key))
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: name).foregroundStyle(DSHTheme.textPrimary)
                if let effort {
                    Text(verbatim: "·").foregroundStyle(DSHTheme.textTertiary)
                    Text(verbatim: effort).foregroundStyle(DSHTheme.textTertiary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DSHTheme.textSecondary)
            }
            .font(.subheadline)
            .lineLimit(1)
        }
        .accessibilityLabel([name, effort].compactMap { $0 }.joined(separator: " · "))
        .accessibilityIdentifier("model.open")
        .task(id: catalog) { if let catalog { PickerNames.shared.remember(catalog) } }
    }

    private var name: String {
        guard let selection else {
            return task == nil ? String(localized: "Model", table: "Pickers") : String(localized: "Change model", table: "Pickers")
        }
        return catalog?.entry(for: selection)?.name ?? PickerNames.shared.names[selection.model] ?? selection.model
    }

    private var effort: String? {
        guard let selection, let model = catalog?.entry(for: selection) else { return nil }
        let effortID = selection.reasoningEffort ?? model.defaultEffort
        return model.efforts.first { $0.id == effortID }?.name
    }
}

/// The model sheet (screens M and X4, STORY §8). Groups by provider with the provider's own
/// model names, reasoning effort as its own group. A selection the host can no longer run is
/// named in an amber note; nothing else is selected in its place, and 应用 stays off until the
/// user picks a model. A provider whose list failed is one row with 重试.
struct ModelPicker: View {
    let store: TaskListStore
    let hostKey: String
    let task: TaskListStore.TaskRow?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ModelSelection?
    @State private var touched = false
    @State private var saving = false
    @State private var error: String?

    private var catalog: ModelCatalog? { store.catalogs[hostKey] }
    private var hostName: String { store.hosts.first { $0.key == hostKey }?.name ?? hostKey }
    /// A task with no recorded selection runs on the host default, so the sheet starts there.
    private var selection: ModelSelection? {
        if let task { return task.modelSelection ?? catalog?.defaultSelection }
        return store.composerSelections[hostKey] ?? catalog?.defaultSelection
    }
    private var unavailable: ModelSelection? {
        guard let catalog, let selection, !catalog.isAvailable(selection) else { return nil }
        return selection
    }
    /// Until the user taps a row, the draft follows the current selection (and the catalog).
    private var effectiveDraft: ModelSelection? { touched ? draft : (unavailable == nil ? selection : nil) }

    private var canApply: Bool {
        guard let effectiveDraft, let catalog else { return false }
        return catalog.isAvailable(effectiveDraft)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(DSHTheme.textSecondary)
                        .accessibilityIdentifier("model.provider")
                    if let gone = unavailable { unavailableNote(gone) }
                    if let catalog {
                        ForEach(groups(catalog), id: \.id) { group in
                            PickerGroupTitle(text: group.name)
                            PickerCard {
                                ForEach(Array(group.models.enumerated()), id: \.element.id) { index, model in
                                    if index > 0 { PickerDivider() }
                                    modelRow(model, provider: group.id, catalog: catalog)
                                }
                            }
                        }
                        if let draft = effectiveDraft, catalog.isAvailable(draft),
                           let model = catalog.entry(for: draft), !model.efforts.isEmpty {
                            PickerGroupTitle(text: String(localized: "Reasoning effort", table: "Pickers"))
                            PickerCard {
                                ForEach(Array(model.efforts.enumerated()), id: \.element.id) { index, effort in
                                    if index > 0 { PickerDivider() }
                                    let current = draft.reasoningEffort ?? model.defaultEffort
                                    PickerRow(id: "model.effort.\(effort.id)", checked: current == effort.id) {
                                        Text(verbatim: effort.name)
                                    } action: {
                                        pick(ModelSelection(provider: draft.provider, model: draft.model, effort: effort.id))
                                    }
                                }
                            }
                        }
                        ForEach(catalog.failures, id: \.id) { failure in failureRow(failure) }
                    } else if let message = store.catalogErrors[hostKey] {
                        failureLine(message, id: "host")
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                    }
                    if let error {
                        Text(verbatim: error)
                            .font(.footnote)
                            .foregroundStyle(DSHTheme.amber)
                            .padding(.top, 12)
                            .accessibilityIdentifier("model.error")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .pickerSheetChrome(title: String(localized: "Model", table: "Pickers"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", table: "Pickers")) { dismiss() }
                        .disabled(saving)
                        .accessibilityIdentifier("model.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Apply", table: "Pickers")) { Task { await apply() } }
                        .disabled(saving || !canApply)
                        .accessibilityIdentifier("model.apply")
                }
            }
            .task {
                if let catalog { PickerNames.shared.remember(catalog) }
                await store.refreshCatalog(hostKey: hostKey)
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private var subtitle: String {
        task.map { !$0.state.isTerminal } == true
            ? String(localized: "From \(hostName) · this task is running", table: "Pickers")
            : String(localized: "From \(hostName)", table: "Pickers")
    }

    /// The catalog's groups, plus the selection that went away, so the user sees which one it was.
    private func groups(_ catalog: ModelCatalog) -> [ModelCatalog.Group] {
        var groups = catalog.groups
        if let gone = unavailable, catalog.entry(for: gone) == nil {
            let missing = ModelCatalog.Model(id: gone.model, name: gone.model)
            if let at = groups.firstIndex(where: { $0.id == gone.provider }) {
                groups[at].models.append(missing)
            } else {
                groups.append(.init(id: gone.provider, name: catalog.providerName(gone.provider), models: [missing]))
            }
        }
        return groups
    }

    @ViewBuilder
    private func modelRow(_ model: ModelCatalog.Model, provider: String, catalog: ModelCatalog) -> some View {
        let gone = unavailable.map { $0.provider == provider && $0.model == model.id } ?? false
        let name = gone ? (lastKnownName(model.id) ?? model.name) : model.name
        if gone {
            PickerRow(id: "model.option.\(provider).\(model.id)", checked: false, enabled: false) {
                Text(verbatim: name).foregroundStyle(DSHTheme.textTertiary)
                Spacer()
                Text("Unavailable", tableName: "Pickers").font(.subheadline).foregroundStyle(DSHTheme.amber)
            } action: {}
            .accessibilityValue("unavailable")
        } else {
            let draft = effectiveDraft
            let checked = draft.map { $0.provider == provider && $0.model == model.id && catalog.isAvailable($0) } ?? false
            PickerRow(id: "model.option.\(provider).\(model.id)", checked: checked) {
                Text(verbatim: model.name)
                Spacer()
                if catalog.isHostDefault(provider: provider, model: model.id) && !checked {
                    Text("Host default", tableName: "Pickers").font(.subheadline).foregroundStyle(DSHTheme.textTertiary)
                }
            } action: {
                if !checked {
                    pick(ModelSelection(provider: provider, model: model.id,
                                        effort: model.defaultEffort))
                }
            }
            .accessibilityValue(catalog.isHostDefault(provider: provider, model: model.id) ? "default" : "")
        }
    }

    /// The name the phone last showed for a model that left the catalog (the id when it never had one).
    private func lastKnownName(_ id: String) -> String? {
        PickerNames.shared.names[id]
    }

    private func unavailableNote(_ gone: ModelSelection) -> some View {
        let name = lastKnownName(gone.model) ?? gone.model
        return Text("Your choice, \(name), is no longer available on \(hostName). No other model was picked for you; choose one.",
                    tableName: "Pickers")
            .font(.subheadline)
            .foregroundStyle(DSHTheme.amber)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(DSHTheme.amberSoft, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(DSHTheme.amberBorder))
            .padding(.top, 14)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("model.unavailable")
    }

    private func failureRow(_ failure: ModelCatalog.Failure) -> some View {
        failureLine(String(localized: "\(failure.name): \(failure.message)", table: "Pickers"), id: failure.id)
    }

    private func failureLine(_ text: String, id: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: text + " ·").foregroundStyle(DSHTheme.textTertiary)
            Button(String(localized: "Retry", table: "Pickers")) {
                Task { await store.refreshCatalog(hostKey: hostKey) }
            }
            .foregroundStyle(DSHTheme.link)
            .accessibilityIdentifier("model.retry.\(id)")
        }
        .font(.subheadline)
        .padding(.top, 16)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model.failure.\(id)")
    }

    private func pick(_ selection: ModelSelection) {
        touched = true
        draft = selection
        error = nil
    }

    private func apply() async {
        guard let draft = effectiveDraft, canApply else { return }
        saving = true
        defer { saving = false }
        do {
            if let task {
                try await store.selectModel(draft, for: task)
            } else {
                store.composerSelections[hostKey] = draft
            }
            dismiss()
        } catch {
            self.error = String(describing: error)
            await store.refreshCatalog(hostKey: hostKey)
        }
    }
}

/// The display names the phone has seen in catalogs, so a model that leaves the catalog is still
/// named the way its provider names it (STORY §8), not by its id.
@MainActor
final class PickerNames {
    static let shared = PickerNames()
    private(set) var names: [String: String] = [:]

    func remember(_ catalog: ModelCatalog) {
        for group in catalog.groups { for model in group.models { names[model.id] = model.name } }
    }
}
