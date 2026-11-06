import DSHCore
import SwiftUI

/// S21 · screen X3: when no host can take a task (`TaskListStore.allHostsOffline`), the blank
/// new session (01) names each host and its last connection (STORY §3). The send key is off
/// (`canSend`), and history still opens from the drawer. When one host is back, the card goes.
///
/// Accessibility contract: `hosts.offlineCard`, and one `hosts.offlineCard.host` per host
/// (label: "name, last connection"; value: `Reachability.token`).
struct AllHostsOfflineCard: View {
    let store: TaskListStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                Text("No host is online. New tasks can't start.", tableName: "Hosts")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DSHTheme.textPrimary)
            } icon: {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(DSHTheme.amber)
            }
            .padding(.bottom, 8)
            ForEach(store.hosts) { host in
                if host.id != store.hosts.first?.id { Divider().overlay(DSHTheme.hairline) }
                OfflineHostLine(host: host)
            }
            Text("Join the same Wi-Fi as your computer, or turn on Tailscale. The app reconnects by itself, and past sessions open while offline.",
                 tableName: "Hosts")
                .font(.subheadline)
                .foregroundStyle(DSHTheme.textSecondary)
                .padding(.top, 10)
        }
        .padding(16)
        .background(DSHTheme.hostsCard, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(DSHTheme.hairline))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hosts.offlineCard")
    }
}

/// "○ MacBook-Pro            10 minutes ago".
private struct OfflineHostLine: View {
    let host: TaskListStore.HostStatus

    var body: some View {
        HStack(spacing: 12) {
            HostDot(reachability: host.reachability)
            Text(verbatim: host.name)
                .foregroundStyle(DSHTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            when
                .font(.subheadline)
                .foregroundStyle(DSHTheme.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityValue(host.reachability.token)
        .accessibilityIdentifier("hosts.offlineCard.host")
    }

    @ViewBuilder
    private var when: some View {
        if case .needsBridgeUpdate = host.reachability {
            Text("DSH needs an update", tableName: "Hosts")
        } else if let last = host.lastConnectedAt {
            Text(last, format: .relative(presentation: .named))
        } else {
            Text("Never connected", tableName: "Hosts")
        }
    }
}
