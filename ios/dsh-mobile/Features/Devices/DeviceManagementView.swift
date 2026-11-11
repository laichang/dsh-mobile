import DSHCore
import SwiftUI

struct DeviceManagementView: View {
    let hostKey: String
    let host: String
    let connection: any HostDeviceManagement
    @State private var list: [PairedDevice]?
    @State private var target: PairedDevice?
    @State private var confirming = false
    @State private var error: String?
    @Environment(\.hostActions) private var actions

    var body: some View {
        List {
            Section(host) {
                NavigationLink {
                    AuditHistoryView(connection: connection)
                } label: {
                    Label("Audit history", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("devices.audit")
            }
            Section("Paired devices") {
                if let list {
                    ForEach(list) { device in
                        VStack(alignment: .leading, spacing: 4) {
                            if device.isCurrent { Text("This device").font(.headline) }
                            Text(device.id).font(.body.monospaced())
                                .accessibilityIdentifier(device.isCurrent ? "device.current" : "device.id.\(device.id)")
                            Text("Paired \(device.pairedAt.formatted())")
                            Text("Last connected \(device.lastSeenAt.formatted())")
                                .foregroundStyle(.secondary)
                            Button("Revoke access", role: .destructive) {
                                target = device
                                confirming = true
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("device.revoke.\(device.id)")
                        }
                    }
                } else if error == nil { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Devices")
        .task { await load() }
        .refreshable { await load() }
        .alert("Revoke device access?", isPresented: $confirming, presenting: target) { device in
            Button("Revoke", role: .destructive) {
                Task {
                    do {
                        switch try await connection.revokeDevice(device) {
                        case .thisDevice: actions.forget(hostKey)
                        case .remaining(let devices): list = devices
                        }
                        error = nil
                    } catch { self.error = String(describing: error) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            if device.isCurrent {
                // The same words as X2 (HostDetailView).
                Text(HostDetailView.revokeThisDeviceMessage(host))
            } else {
                Text("Device \(device.id) will disconnect from \(host). It must pair again to reconnect.")
            }
        }
    }

    private func load() async {
        do { list = try await connection.listDevices(); error = nil }
        catch { self.error = String(describing: error) }
    }
}

private struct AuditHistoryView: View {
    let connection: any HostDeviceManagement
    @State private var entries: [DeviceAuditEntry] = []
    @State private var next = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.action).font(.headline)
                    Text(entry.detail)
                    Text("\(entry.actor) · \(entry.device)").foregroundStyle(.secondary)
                    Text(entry.at.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("audit.\(entry.action)")
            }
            if let error { Text(error).foregroundStyle(.red) }
            if loading { ProgressView() }
            else if !next.isEmpty { Button("Load earlier events") { Task { await load(before: next) } } }
            else if entries.isEmpty && error == nil { Text("No events yet.") }
        }
        .navigationTitle("Audit history")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load(before: String = "") async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await connection.audit(beforeID: before)
            if before.isEmpty { entries = page.entries } else { entries.append(contentsOf: page.entries) }
            next = page.nextBeforeID
            error = nil
        } catch { self.error = String(describing: error) }
    }
}
