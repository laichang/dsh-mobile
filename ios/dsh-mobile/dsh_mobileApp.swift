import DSHCore
import SwiftUI

@main
struct dsh_mobileApp: App {
    @State private var app = AppModel()
    @State private var showFirstTask = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            root
                // DESIGN.md "Visual language": the app always uses dark mode (T1).
                .preferredColorScheme(.dark)
                .sheet(isPresented: $app.showingScanner) {
                    ScannerView(found: { app.openPairingCode($0) }, cancel: { app.showingScanner = false })
                }
                #if DEBUG
                // dshm:// is registered only in the Debug Info.plist (ARCHITECTURE D16).
                .onOpenURL { url in
                    if DebugDeepLink.route(url) != nil { app.openPairingCode(url.absoluteString) }
                }
                #endif
        }
        // S2: refresh on foreground (resume from the cursor); iOS drops sockets in the background.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: app.store?.foreground()
            case .background: app.store?.background()
            default: break
            }
        }
    }

    // The pairing screen replaces the main screen rather than using a sheet: a sheet presented
    // from onOpenURL didn't show up in XCUITest's accessibility tree (T0 Log).
    @ViewBuilder private var root: some View {
        if let route = app.pairingRoute {
            PairingView(route: route) {
                let wasUnpaired = !app.hasSavedHosts
                app.closePairing()
                showFirstTask = wasUnpaired && app.hasSavedHosts
            }
        } else if let store = app.store {
            ShellView(store: store, showFirstTask: $showFirstTask) { app.showingScanner = true }
                .id(ObjectIdentifier(store))
        } else if app.hasSavedHosts {
            ContentUnavailableView {
                Label("Couldn't open your paired computers", systemImage: "lock.trianglebadge.exclamationmark")
            } actions: {
                Button("Try again") { app.retrySavedHosts() }
                Button("Pair a computer") { app.showingScanner = true }
            }
        } else {
            WelcomeView { app.showingScanner = true }
        }
    }
}

/// With no paired computer, explain what the phone can do and how to connect it.
struct WelcomeView: View {
    let pair: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Connect your computer")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Send tasks from your phone, follow their progress, and answer approval requests. DeepSeek Harness runs the tasks on your computer.")
                    .font(.body)
                    .accessibilityIdentifier("firstRun.purpose")
                Text("To get started, you need a computer running DeepSeek Harness (DSH) with the dsh-mobile bridge enabled.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("firstRun.requiresHost")
                Button("Pair a computer", action: pair)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("pairing.scan")
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .defaultScrollAnchor(.center, for: .alignment)
    }
}
