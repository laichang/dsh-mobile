import DSHCore
import SwiftUI

/// Where a pairing code lands: from the QR scanner, a pasted link, or (Debug) the `dshm://pair?…`
/// deep link. Shows which host the code is for, pairs on tap, and reports the outcome.
/// Accessibility identifiers (ARCHITECTURE D16): `pairing.view`, `pairing.status` (value
/// reviewing / pairing / paired / failed / invalid), `pairing.confirm`, `pairing.done`, `pairing.close`.
struct PairingView: View {
    let route: AppModel.PairingRoute
    let close: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch route {
                case .offer(let model): OfferPairingView(model: model, close: close)
                case .invalid(let why): invalid(why)
                }
            }
            .navigationTitle("Pair a host")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func invalid(_ why: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode").font(.largeTitle).foregroundStyle(.secondary)
            Text("This isn't a pairing code dsh-mobile can use.")
                .font(.headline)
            Text(why).font(.footnote).foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(why)
                .accessibilityValue("invalid")
                .accessibilityIdentifier("pairing.status")
            Button("Close", action: close)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("pairing.close")
        }
        .multilineTextAlignment(.center)
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pairing.view")
    }
}

private struct OfferPairingView: View {
    let model: PairingModel
    let close: () -> Void

    var body: some View {
        List {
            Section {
                LabeledContent("Host", value: model.offer.hostName.isEmpty ? "Unnamed host" : model.offer.hostName)
                LabeledContent("Addresses", value: model.offer.addresses.map(\.description).joined(separator: "\n"))
                LabeledContent("Host key", value: fingerprint)
                LabeledContent("Code expires", value: model.offer.expiresAt.formatted(date: .omitted, time: .shortened))
            } footer: {
                Text("Pairing lets this phone send tasks to that host. Everything between them is end-to-end encrypted; the code works once.")
            }
            Section {
                status
                actions
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pairing.view")
    }

    /// First 8 bytes of the host key, so the user can compare with the host's terminal if they like.
    private var fingerprint: String {
        model.offer.hostKey.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private var status: some View {
        HStack(spacing: 8) {
            switch model.state {
            case .reviewing: Image(systemName: "lock.shield").foregroundStyle(.secondary)
            case .pairing: ProgressView().controlSize(.small)
            case .paired: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(statusText).font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusText)
        .accessibilityValue(model.state.token)
        .accessibilityIdentifier("pairing.status")
    }

    private var statusText: String {
        switch model.state {
        case .reviewing: String(localized: "Ready to pair")
        case .pairing: String(localized: "Pairing…")
        case .paired(let host): String(localized: "Paired with \(host.name.isEmpty ? String(localized: "the host") : host.name)")
        case .failed(let message): String(localized: "Couldn't pair: \(message)")
        }
    }

    @ViewBuilder private var actions: some View {
        switch model.state {
        case .reviewing, .pairing:
            Button("Pair") { Task { await model.pair() } }
                .disabled(model.state == .pairing)
                .accessibilityIdentifier("pairing.confirm")
            Button("Cancel", role: .cancel, action: close)
                .accessibilityIdentifier("pairing.close")
        case .paired:
            Button("Done", action: close)
                .bold()
                .accessibilityIdentifier("pairing.done")
        case .failed:
            Button("Close", action: close)
                .accessibilityIdentifier("pairing.close")
        }
    }
}
