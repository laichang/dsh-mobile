import DSHCore
import SwiftUI

/// The thin workspace drawer (02): 新建会话, 所有任务, and the sessions in groups by host.
/// Each host group starts with the host's status, its channel and its device management (S1, S2,
/// S10), so a host's state shows where its sessions are.
///
/// Registration point: each section is one line in `body`. S14's `DrawerHostTree` shows each host
/// as host › workspace › session with status marks, the "2 / 3" hosts online, and settings.
struct DrawerView: View {
    let store: TaskListStore
    let pair: () -> Void
    @Environment(ShellModel.self) private var shell

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { brand; Spacer(minLength: 8); DrawerHostsOnline(hosts: store.hosts).opensHostsSheet() }
                    DrawerNewSessionButton()
                    DrawerAllTasksRow(store: store)
                    ForEach(store.hosts) { host in
                        DrawerHostTree(store: store, host: host)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            Divider().overlay(DSHTheme.hairline)
            DrawerFooter(pair: pair)
        }
        .background(DSHTheme.slate.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawer")
    }

    private var brand: some View {
        HStack(spacing: 8) {
            Text(verbatim: "deepseek").font(.title2.weight(.bold))
            Text(verbatim: "HARNESS")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(DSHTheme.textPrimary, lineWidth: 1))
        }
        .foregroundStyle(DSHTheme.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct DrawerNewSessionButton: View {
    @Environment(ShellModel.self) private var shell

    var body: some View {
        Button { shell.open(.newSession) } label: {
            Label("drawer.newSession", systemImage: "plus")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(DSHTheme.textPrimary)
        .accessibilityIdentifier("drawer.new")
    }
}

private struct DrawerAllTasksRow: View {
    let store: TaskListStore
    @Environment(ShellModel.self) private var shell

    var body: some View {
        let sections = store.sections
        Button { shell.open(.allTasks) } label: {
            HStack {
                Label("All tasks", systemImage: "list.bullet")
                Spacer()
                if !sections.waitingOnMe.isEmpty {
                    Text("\(sections.waitingOnMe.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(DSHTheme.amber, in: .capsule)
                }
                if !sections.running.isEmpty {
                    Label("\(sections.running.count)", systemImage: "circle.dotted")
                        .font(.caption)
                        .foregroundStyle(DSHTheme.textSecondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.drawerPress) // S23 F1
        .foregroundStyle(DSHTheme.textPrimary)
        .accessibilityIdentifier("drawer.allTasks")
    }
}

private struct DrawerFooter: View {
    let pair: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: pair) {
                Image(systemName: "qrcode.viewfinder").font(.title3)
            }
            .accessibilityLabel("Pair a host")
            .accessibilityIdentifier("pairing.scan")
            DrawerSettingsButton().padding(.leading, 16)
        }
        .foregroundStyle(DSHTheme.textSecondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
