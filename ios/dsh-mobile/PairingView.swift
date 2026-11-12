import DSHCore
import DSHFeatures
import SwiftUI

/// Where a pairing code lands: from the QR scanner, a pasted link, or (Debug) the `dshm://pair?…`
/// deep link. Shows which host the code is for, pairs on tap, and reports the outcome.
/// Accessibility identifiers: `pairing.view`, `pairing.status` (value
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSHTheme.canvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pairing.view")
    }
}

private struct OfferPairingView: View {
    let model: PairingModel
    let close: () -> Void

    // In the DSH style of 08 (canvas, one card, a white primary button), not a grouped List.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DSHWordmark().padding(.top, 12)
                VStack(alignment: .leading, spacing: 0) {
                    row("Host", model.offer.hostName.isEmpty ? String(localized: "Unnamed host") : model.offer.hostName)
                    row("Addresses", model.offer.addressDescriptions.joined(separator: "\n"))
                    row("Host key", fingerprint, mono: true)
                    row("Code expires", model.offer.expiresAt.formatted(date: .omitted, time: .shortened), last: true)
                }
                .padding(.horizontal, 16)
                .background(Color(hex: 0x1F2023), in: .rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(DSHTheme.hairline))
                Text("Pairing lets this phone send tasks to that host. Everything between them is end-to-end encrypted; the code works once.")
                    .font(.footnote)
                    .foregroundStyle(DSHTheme.textTertiary)
                status
                actions
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(DSHTheme.canvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pairing.view")
    }

    private func row(_ title: LocalizedStringKey, _ value: String, mono: Bool = false, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            LabeledContent {
                Text(value)
                    .font(mono ? DSHTheme.mono(.footnote) : .body)
                    .foregroundStyle(DSHTheme.textPrimary)
                    .multilineTextAlignment(.trailing)
            } label: {
                Text(title).foregroundStyle(DSHTheme.textSecondary)
            }
            .padding(.vertical, 12)
            if !last { Divider().overlay(DSHTheme.hairline) }
        }
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
            Text(statusText).font(.footnote).foregroundStyle(DSHTheme.textSecondary)
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
        VStack(spacing: 10) {
            switch model.state {
            case .reviewing, .pairing:
                Button { Task { await model.pair() } } label: { primary(Text("Pair")) }
                    .buttonStyle(.plain)
                    .disabled(model.state == .pairing)
                    .accessibilityIdentifier("pairing.confirm")
                Button(action: close) { secondary(Text("Cancel")) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pairing.close")
            case .paired:
                Button(action: close) { primary(Text("Done")) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pairing.done")
            case .failed:
                Button(action: close) { secondary(Text("Close")) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pairing.close")
            }
        }
    }

    private func primary(_ label: Text) -> some View {
        label.font(.body.weight(.semibold))
            .foregroundStyle(DSHTheme.canvas)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(DSHTheme.textPrimary, in: .rect(cornerRadius: 18))
    }

    private func secondary(_ label: Text) -> some View {
        label.font(.body.weight(.semibold))
            .foregroundStyle(DSHTheme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(DSHTheme.bubble, in: .rect(cornerRadius: 18))
    }
}
