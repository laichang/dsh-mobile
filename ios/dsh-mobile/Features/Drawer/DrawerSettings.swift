import DSHCore
import DSHProtocol
import SwiftUI

/// The settings button at the bottom of the drawer, beside pairing (screen 02).
struct DrawerSettingsButton: View {
    @Environment(ShellModel.self) private var shell

    var body: some View {
        Button { shell.present(.settings) } label: {
            Image(systemName: "gearshape").font(.title3)
        }
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("drawer.settings")
    }
}

/// Settings: the paired hosts as this phone sees them, and the app version. Device
/// management and audit stay in each host (H); S21 adds the hosts sheet.
struct DrawerSettingsSheet: View {
    let store: TaskListStore

    var body: some View {
        NavigationStack {
            List {
                Section("Hosts") {
                    ForEach(store.hosts) { host in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: host.name)
                            Text(verbatim: "\(host.reachability.token) · \(host.channelName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings.host")
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    LabeledContent("Protocol", value: "\(DSHProtocolInfo.version)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetDoneButton() }
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
