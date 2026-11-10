import DSHCore
import DSHProtocol
import SwiftUI

/// One host (screen X2), pushed in the hosts sheet: its paired devices (this device is
/// marked), revoke with a confirmation, and its audit records with "load older" (STORY §9).
/// A revoke of this device ends its access to the host: the app forgets the host, and with no
/// host left it shows 08.
///
/// Accessibility contract: `host.detail` (label: the host name), `device.current` (label: this
/// device's id), `device.id.<id>`, `device.revoke.<id>`, `device.revoke.confirm`,
/// `audit.<action>` (label: the whole record), `audit.loadOlder`. The `device.*` and `audit.*`
/// identifiers are the ones of S10's `DeviceManagementView`.
struct HostDetailView: View {
    let store: TaskListStore
    let hostKey: String
    @Environment(\.hostActions) private var actions
    @Environment(ShellModel.self) private var shell
    @State private var list: Dshm_V1_DeviceList?
    @State private var entries: [Dshm_V1_AuditEntry] = []
    @State private var nextBeforeID = ""
    @State private var loadingOlder = false
    @State private var error: String?
    @State private var target: Dshm_V1_PairedDevice?

    var body: some View {
        let host = store.hosts.first { $0.key == hostKey }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let host { status(host) }
                if let connection = store.deviceManagement(for: hostKey) {
                    content(connection)
                } else {
                    Text("Connect to this host to see its devices and audit records.", tableName: "Hosts")
                        .foregroundStyle(DSHTheme.textSecondary)
                        .padding(.top, 12)
                }
                if let error {
                    Text(verbatim: error).font(.footnote).foregroundStyle(DSHTheme.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(DSHTheme.hostsSheet.ignoresSafeArea())
        .navigationTitle(host?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(host?.name ?? "")
        .accessibilityIdentifier("host.detail")
        .task(id: store.deviceManagement(for: hostKey) != nil) { await load() }
        .alert(confirmTitle, isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
               presenting: target) { device in
            Button(role: .destructive) { revoke(device) } label: { Text("Revoke", tableName: "Hosts") }
                .accessibilityIdentifier("device.revoke.confirm")
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "Hosts") }
        } message: { device in
            if device.id == list?.currentDeviceID {
                // Say what happens; the host leaves the drawer and is not retried.
                Text(Self.revokeThisDeviceMessage(host?.name ?? ""))
            } else {
                Text("Device \(device.id) will lose access to \(host?.name ?? ""). It must pair again to reconnect.", tableName: "Hosts")
            }
        }
    }

    /// The message of the alert before a revoke of this device (X2 and the drawer's
    /// "Devices and audit").
    static func revokeThisDeviceMessage(_ host: String) -> String {
        String(localized: "This phone will be removed from \(host). \(host) will leave the drawer, with nothing left to tap, and the phone will not reconnect to it. To use it again, pair again.", table: "Hosts")
    }

    private var confirmTitle: Text {
        target?.id == list?.currentDeviceID
            ? Text("Revoke this device?", tableName: "Hosts")
            : Text("Revoke this device's access?", tableName: "Hosts")
    }

    private func status(_ host: TaskListStore.HostStatus) -> some View {
        HStack(spacing: 4) {
            HostChannelLabel(host: host)
            Text(verbatim: "·").foregroundStyle(DSHTheme.textTertiary)
            switch host.reachability {
            case .online: Text("Online", tableName: "Hosts")
            case .connecting: Text("Connecting…", tableName: "Hosts")
            case .needsBridgeUpdate: Text("DSH needs an update", tableName: "Hosts").foregroundStyle(DSHTheme.amber)
            case .offline: HostLastConnection(date: host.lastConnectedAt)
            }
        }
        .font(.subheadline)
        .foregroundStyle(DSHTheme.textSecondary)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func content(_ connection: HostConnection) -> some View {
        sectionTitle(Text("Paired devices", tableName: "Hosts"))
        card {
            if let list {
                ForEach(Array(list.devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { Divider().overlay(DSHTheme.hairline) }
                    DeviceRow(device: device, current: device.id == list.currentDeviceID) { target = device }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(16)
            }
        }
        sectionTitle(Text("Audit records", tableName: "Hosts"))
        card {
            if entries.isEmpty {
                Text("No records yet.", tableName: "Hosts").foregroundStyle(DSHTheme.textSecondary).padding(16)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().overlay(DSHTheme.hairline) }
                AuditRow(entry: entry)
            }
        }
        if loadingOlder {
            ProgressView().frame(maxWidth: .infinity)
        } else if !nextBeforeID.isEmpty {
            Button { Task { await loadOlder(connection) } } label: {
                Text("Load older records", tableName: "Hosts").foregroundStyle(DSHTheme.blue)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .accessibilityIdentifier("audit.loadOlder")
        }
    }

    private func sectionTitle(_ text: Text) -> some View {
        text.font(.subheadline).foregroundStyle(DSHTheme.textTertiary).padding(.top, 14)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSHTheme.hostsCard, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(DSHTheme.hairline))
    }

    private func load() async {
        guard let connection = store.deviceManagement(for: hostKey) else { return }
        do {
            list = try await connection.listDevices()
            let page = try await connection.audit()
            entries = page.entries
            nextBeforeID = page.nextBeforeID
            error = nil
        } catch { self.error = String(describing: error) }
    }

    private func loadOlder(_ connection: HostConnection) async {
        guard !loadingOlder, !nextBeforeID.isEmpty else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await connection.audit(beforeID: nextBeforeID)
            entries.append(contentsOf: page.entries)
            nextBeforeID = page.nextBeforeID
            error = nil
        } catch { self.error = String(describing: error) }
    }

    private func revoke(_ device: Dshm_V1_PairedDevice) {
        guard let connection = store.deviceManagement(for: hostKey) else { return }
        let isCurrent = device.id == list?.currentDeviceID
        Task {
            do {
                list = try await connection.revokeDevice(device.id)
                error = nil
                if isCurrent {
                    // This phone has no access to the host any more.
                    shell.sheet = nil
                    actions.forget(hostKey)
                } else {
                    await load()
                }
            } catch where isCurrent && HostConnection.isDeviceRefusal(error) {
                // The close 4003 came before the response; the revoke took effect.
                shell.sheet = nil
                actions.forget(hostKey)
            } catch { self.error = String(describing: error) }
        }
    }
}

/// "▯ This device / dshm-a3f9c21e / paired 11/3 · last connected just now    Revoke".
private struct DeviceRow: View {
    let device: Dshm_V1_PairedDevice
    let current: Bool
    let revoke: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "iphone")
                .foregroundStyle(DSHTheme.textSecondary)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if current {
                    Text("This device", tableName: "Hosts").font(.body.weight(.semibold))
                }
                Text(verbatim: device.id)
                    .font(DSHTheme.mono(current ? .subheadline : .body))
                    .foregroundStyle(current ? DSHTheme.textSecondary : DSHTheme.textPrimary)
                    .accessibilityLabel(device.id)
                    .accessibilityIdentifier(current ? "device.current" : "device.id.\(device.id)")
                Text("Paired \(date(device.pairedAtMs), format: .dateTime.month(.defaultDigits).day()) · last connected \(date(device.lastSeenAtMs), format: .relative(presentation: .named))",
                     tableName: "Hosts")
                    .font(.footnote)
                    .foregroundStyle(DSHTheme.textTertiary)
            }
            Spacer(minLength: 8)
            Button(action: revoke) {
                Text("Revoke", tableName: "Hosts").foregroundStyle(DSHTheme.red)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("device.revoke.\(device.id)")
        }
        .foregroundStyle(DSHTheme.textPrimary)
        .padding(16)
    }
}

/// "Approval allowed / bash rm -rf … / owner · dshm-a3f9c21e    11:02".
private struct AuditRow: View {
    let entry: Dshm_V1_AuditEntry

    var body: some View {
        let at = date(entry.atMs)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(entry.action), tableName: "Hosts").font(.body.weight(.semibold))
                Spacer()
                Group {
                    if Calendar.current.isDateInToday(at) {
                        Text(at, format: .dateTime.hour().minute())
                    } else {
                        Text(at, format: .dateTime.month(.defaultDigits).day().hour().minute())
                    }
                }
                .font(.footnote)
                .foregroundStyle(DSHTheme.textTertiary)
            }
            if !entry.detail.isEmpty {
                Text(verbatim: entry.detail).font(DSHTheme.mono(.subheadline)).lineLimit(3)
            }
            Text(verbatim: "\(entry.actor) · \(entry.device)")
                .font(.footnote)
                .foregroundStyle(DSHTheme.textTertiary)
        }
        .foregroundStyle(DSHTheme.textPrimary)
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("audit.\(entry.action)")
    }
}

private func date(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
}
