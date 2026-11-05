import DSHCore
import SwiftUI

/// The one screen: type a sentence, send it, watch the answer stream back. The host row says
/// which host and channel it goes over (`host.channel`: "noise", or "plaintext" on Debug's
/// loopback dev path).
struct ContentView: View {
    @Bindable var store: TaskStore
    let hostLabel: String
    let pair: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                hostRow
                    .padding(.horizontal)
                    .padding(.top, 4)
                statusRow
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                ScrollView {
                    Text(store.transcript.isEmpty ? "Send a task to your DSH host." : store.transcript)
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
            .toolbar {
                Button(action: pair) { Image(systemName: "qrcode.viewfinder") }
                    .accessibilityLabel("Pair a host")
                    .accessibilityIdentifier("pairing.scan")
            }
        }
    }

    private var hostRow: some View {
        let encrypted = store.channelName == "noise"
        return HStack(spacing: 6) {
            Image(systemName: encrypted ? "lock.fill" : "lock.open")
                .foregroundStyle(encrypted ? .green : .orange)
            Text(encrypted ? "\(hostLabel) · end-to-end encrypted" : "\(hostLabel) · plaintext")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(encrypted ? "\(hostLabel), encrypted" : "\(hostLabel), plaintext")
        .accessibilityValue(store.channelName)
        .accessibilityIdentifier("host.channel")
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
        case .running: "Running on \(hostLabel)"
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
