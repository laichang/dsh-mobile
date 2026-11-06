import DSHCore
import DSHProtocol
import SwiftUI

/// The model pill (S6): the composer's choice, or a running task's. It opens `ModelPicker` as a
/// sheet (`SheetRoute.model`).
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
            Label(label, systemImage: "slider.horizontal.3")
                .font(.subheadline)
                .lineLimit(1)
        }
        .accessibilityIdentifier("model.open")
    }

    private var label: String {
        guard let selection else { return task == nil ? "Model" : "Change model" }
        guard let model = catalog?.entry(for: selection) else { return selection.model }
        let effortID = selection.hasReasoningEffort ? selection.reasoningEffort : model.defaultEffort
        let effort = model.efforts.first { $0.id == effortID }?.name
        return [model.name, effort].compactMap { $0 }.joined(separator: " · ")
    }

}

struct ModelPicker: View {
    let store: TaskListStore
    let hostKey: String
    let task: TaskListStore.TaskRow?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ModelSelection?
    @State private var saving = false
    @State private var error: String?

    private var catalog: ModelCatalog? { store.catalogs[hostKey] }
    private var selection: ModelSelection? {
        if let task { return task.modelSelection }
        return store.composerSelections[hostKey] ?? catalog?.defaultSelection
    }

    var body: some View {
        NavigationStack {
            List {
                if let message = store.catalogErrors[hostKey] {
                    Text(message).foregroundStyle(.orange)
                    Button("Retry") { Task { await store.refreshCatalog(hostKey: hostKey) } }
                }
                if let catalog {
                    ForEach(catalog.groups, id: \.id) { group in
                        Section(group.name) {
                            ForEach(group.models, id: \.id) { model in
                                let selected = draft?.provider == group.id && draft?.model == model.id
                                choice(model.name, checked: selected, id: "model.option.\(group.id).\(model.id)") {
                                    if !selected {
                                        draft = ModelSelection(provider: group.id, model: model.id,
                                            effort: model.hasDefaultEffort ? model.defaultEffort : nil)
                                    }
                                }
                            }
                        }
                    }
                    if let draft, let model = catalog.entry(for: draft), !model.efforts.isEmpty {
                        Section("Reasoning effort") {
                            ForEach(model.efforts, id: \.id) { effort in
                                let current = draft.hasReasoningEffort ? draft.reasoningEffort : model.defaultEffort
                                choice(effort.name, checked: current == effort.id, id: "model.effort.\(effort.id)") {
                                    self.draft = ModelSelection(provider: draft.provider, model: draft.model, effort: effort.id)
                                }
                            }
                        }
                    }
                    ForEach(catalog.failures, id: \.id) { failure in
                        Text("\(failure.name): \(failure.message)").foregroundStyle(.secondary)
                    }
                } else if store.catalogErrors[hostKey] == nil {
                    ProgressView()
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("Model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { Task { await apply() } }
                        .disabled(saving || !available)
                        .accessibilityIdentifier("model.apply")
                }
            }
            .onAppear { if draft == nil { draft = selection } }
            .task {
                await store.refreshCatalog(hostKey: hostKey)
                if draft == nil { draft = selection ?? catalog?.defaultSelection }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private var available: Bool {
        guard let draft, let entry = catalog?.entry(for: draft) else { return false }
        return !draft.hasReasoningEffort || entry.efforts.contains { $0.id == draft.reasoningEffort }
    }

    private func choice(_ name: String, checked: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(name)
                Spacer()
                if checked { Image(systemName: "checkmark") }
            }
        }
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private func apply() async {
        guard let draft else { return }
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
