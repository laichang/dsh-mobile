import DSHCore
import SwiftUI

/// T0's one screen: type a sentence, send it, watch the answer stream back.
struct ContentView: View {
    @Bindable var store: TaskStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusRow
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                if !store.milestones.isEmpty {
                    // S3: milestone summary by default; the timeline on demand.
                    NavigationLink {
                        MilestoneTimelineView(store: store)
                    } label: {
                        MilestoneCard(timeline: store.milestones)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(store.milestones.headline)
                    .accessibilityValue(store.milestones.progressToken)
                    .accessibilityIdentifier("milestone.card")
                    .padding(.horizontal)
                }
                ScrollView {
                    Text(store.transcript.isEmpty ? "Send a task to the DSH on this Mac." : store.transcript)
                        .foregroundStyle(store.transcript.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                        .accessibilityIdentifier("transcript.text")
                        .accessibilityValue(store.transcript)
                }
                .defaultScrollAnchor(.bottom)
                composer
                    .padding()
            }
            .navigationTitle("dsh-mobile")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            switch store.status {
            case .connecting, .running:
                ProgressView().controlSize(.small)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .idle:
                Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            }
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusText)
        .accessibilityValue(store.status.token)
        .accessibilityIdentifier("task.status")
    }

    private var statusText: String {
        switch store.status {
        case .idle: "Ready"
        case .connecting: "Connecting to the bridge…"
        case .running: "Running on this Mac"
        case .completed: "Done"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("One sentence for your agent", text: $store.prompt, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("composer.prompt")
                .onSubmit { Task { await store.send() } }
            Button {
                Task { await store.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .disabled(!store.canSend)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("composer.send")
        }
    }
}
