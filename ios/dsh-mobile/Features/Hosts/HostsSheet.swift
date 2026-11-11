import DSHCore
import SwiftUI

/// The hosts sheet (screen H), from the "2 / 3" pill in the drawer. Every host is a row of
/// the same shape (STORY §2): online with its channel, default model and the address in use; an
/// unsupported DSH with the installed and supported versions; offline with its last connection,
/// the last error of each address, and what waits on it (STORY §3). A row opens the host's devices and audit records (X2, `HostDetailView`).
///
/// Accessibility contract: `hosts.sheet`, `hosts.summary` (value "online/total"), `hosts.row`
/// (label: name and state, value: `Reachability.token`), `hosts.pair`.
struct HostsSheet: View {
    let store: TaskListStore
    @Environment(\.hostActions) private var actions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(store.hosts) { host in
                        NavigationLink(value: host.key) { HostRow(store: store, host: host) }
                            .buttonStyle(.plain)
                        if host.id != store.hosts.last?.id { Divider().overlay(DSHTheme.hairline) }
                    }
                    pairButton.padding(.top, 24)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(DSHTheme.hostsSheet.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { key in
                HostDetailView(store: store, hostKey: key)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hosts.sheet")
    }

    private var header: some View {
        let online = store.hosts.filter { $0.reachability == .online }.count
        return HStack(alignment: .firstTextBaseline) {
            Text("Hosts", tableName: "Hosts")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Text("\(online) / \(store.hosts.count) online", tableName: "Hosts")
                .foregroundStyle(DSHTheme.textSecondary)
                .accessibilityValue("\(online)/\(store.hosts.count)")
                .accessibilityIdentifier("hosts.summary")
        }
        .foregroundStyle(DSHTheme.textPrimary)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private var pairButton: some View {
        Button {
            dismiss()
            // The scanner is a sheet of the app's root: present it once this sheet is gone.
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                actions.pair()
            }
        } label: {
            Label { Text("Pair a new host", tableName: "Hosts") } icon: { Image(systemName: "qrcode.viewfinder") }
                .font(.body.weight(.semibold))
                .foregroundStyle(DSHTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(DSHTheme.hostsButton, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hosts.pair")
    }
}

/// One host on screen H: icon, name and status dot, then one or two lines on its state.
private struct HostRow: View {
    let store: TaskListStore
    let host: TaskListStore.HostStatus

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(online ? DSHTheme.textPrimary : DSHTheme.textSecondary)
                .frame(width: 44, height: 44)
                .background(DSHTheme.hostsIcon, in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: host.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(online ? DSHTheme.textPrimary : DSHTheme.textSecondary)
                        .lineLimit(1)
                    HostDot(reachability: host.reachability)
                }
                details.font(.subheadline)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DSHTheme.textTertiary)
                .padding(.top, 14)
        }
        .padding(.vertical, 14)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(host.reachability.token)
        .accessibilityIdentifier("hosts.row")
    }

    private var online: Bool { host.reachability == .online }

    @ViewBuilder
    private var details: some View {
        switch host.reachability {
        case .online:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    HostChannelLabel(host: host)
                    if let model = defaultModel {
                        Text(verbatim: "·").foregroundStyle(DSHTheme.textTertiary)
                        Text("Default \(model)", tableName: "Hosts")
                            .foregroundStyle(DSHTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                // Which of the host's addresses this phone uses (LAN, Tailscale, ...).
                if let address = host.address {
                    Text("Via \(address.description)", tableName: "Hosts")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(DSHTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        case .connecting:
            Text("Connecting…", tableName: "Hosts").foregroundStyle(DSHTheme.textSecondary)
        case .needsBridgeUpdate(let version, let supported):
            VStack(alignment: .leading, spacing: 2) {
                (Text("DSH needs an update", tableName: "Hosts").foregroundStyle(DSHTheme.amber)
                    + Text(verbatim: ": ")
                    + Text("installed \(version), supported \(supported)", tableName: "Hosts"))
                Text("No new tasks until it is updated", tableName: "Hosts")
            }
            .foregroundStyle(DSHTheme.textSecondary)
        case .offline:
            VStack(alignment: .leading, spacing: 2) {
                HostLastConnection(date: host.lastConnectedAt)
                    .foregroundStyle(DSHTheme.textSecondary)
                // Every address was tried; the last error of each. In words when it
                // says why the bridge does not answer, with the error after it.
                ForEach(host.addressFailures, id: \.endpoint.description) { failure in
                    if let kind = failure.kind {
                        (Text(verbatim: "\(failure.endpoint.description) · ") + kind.sentence
                            + Text(verbatim: " (\(failure.reason))"))
                            .font(.footnote)
                            .foregroundStyle(DSHTheme.textTertiary)
                            .lineLimit(3)
                    } else {
                        Text(verbatim: "\(failure.endpoint.description) · \(failure.reason)")
                            .font(.footnote)
                            .foregroundStyle(DSHTheme.textTertiary)
                            .lineLimit(2)
                    }
                }
                if let fix = host.offlineReason?.kind?.fix {
                    fix.foregroundStyle(DSHTheme.amber)
                }
                let waiting = store.tasks.filter { $0.hostKey == host.key && $0.state == .waitingOnUser }.count
                if waiting > 0 {
                    Text("\(waiting) waiting on you until it is back", tableName: "Hosts")
                        .foregroundStyle(DSHTheme.amber)
                }
            }
        }
    }

    /// The host's default model, as the host names it (STORY §8: no rewording).
    private var defaultModel: String? {
        guard let catalog = store.catalogs[host.key], catalog.hasDefaultSelection else { return nil }
        let selection = catalog.defaultSelection
        let name = catalog.entry(for: selection)?.name ?? ""
        return name.isEmpty ? selection.model : name
    }
}

/// Green when online, amber when its DSH needs an update, a ring when offline or connecting.
struct HostDot: View {
    let reachability: TaskListStore.Reachability

    var body: some View {
        Group {
            switch reachability {
            case .online: Circle().fill(DSHTheme.green)
            case .needsBridgeUpdate: Circle().fill(DSHTheme.amber)
            case .offline, .connecting: Circle().stroke(DSHTheme.textTertiary, lineWidth: 1.5)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

/// "🔒 End-to-end encrypted" on a Noise channel; Debug's loopback path says it is not encrypted.
struct HostChannelLabel: View {
    let host: TaskListStore.HostStatus

    var body: some View {
        if host.channelName == "noise" {
            Label { Text("End-to-end encrypted", tableName: "Hosts") } icon: { Image(systemName: "lock") }
                .foregroundStyle(DSHTheme.green)
                .labelStyle(.tightIcon)
        } else {
            Label { Text("Not encrypted (debug)", tableName: "Hosts") } icon: { Image(systemName: "lock.open") }
                .foregroundStyle(DSHTheme.textSecondary)
                .labelStyle(.tightIcon)
        }
    }
}

/// "Offline · last connected 2 hours ago", or "never connected".
struct HostLastConnection: View {
    let date: Date?

    var body: some View {
        if let date {
            Text("Offline · last connected \(date, format: .relative(presentation: .named))", tableName: "Hosts")
        } else {
            Text("Offline · never connected", tableName: "Hosts")
        }
    }
}

extension LabelStyle where Self == TightIconLabelStyle {
    static var tightIcon: TightIconLabelStyle { .init() }
}

struct TightIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title.lineLimit(1)
        }
    }
}
