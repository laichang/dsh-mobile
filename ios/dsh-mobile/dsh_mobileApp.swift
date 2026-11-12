import DSHCore
import DSHFeatures
import SwiftUI

@main
struct dsh_mobileApp: App {
    @State private var app = AppModel()
    @State private var showFirstTask = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            root
                // the DSHTheme visual language: the app always uses dark mode.
                .preferredColorScheme(.dark)
                .environment(\.hostActions, HostActions(pair: { app.startPairing() }, forget: { app.forgetHost($0) }))
                .environment(\.transcriber, app.transcriber)
                // A host revoked this phone; the app forgot it. Said once.
                .alert(Text("Access removed", tableName: "Hosts"), isPresented: Binding(
                    get: { app.revokedNotice != nil || app.pairingRemovalError != nil },
                    set: { if !$0 { app.revokedNotice = nil; app.pairingRemovalError = nil } })) {
                    Button(role: .cancel) {} label: { Text("OK", tableName: "Hosts") }
                } message: {
                    if let error = app.pairingRemovalError { Text(verbatim: error) }
                    else { Text("\(app.revokedNotice ?? "") revoked this phone's access. To use it again, pair it again.", tableName: "Hosts") }
                }
                .sheet(isPresented: $app.showingScanner) {
                    ScannerView(mode: app.scannerMode, found: { app.openPairingCode($0) }, cancel: { app.showingScanner = false })
                }
                #if DEBUG
                // The Live Activities as ActivityKit has them, for UI tests.
                .overlay(alignment: .topLeading) {
                    if ProcessInfo.processInfo.arguments.contains("-DSHMLiveActivityProbe") {
                        Text(verbatim: "·").font(.system(size: 2)).opacity(0.02).allowsHitTesting(false)
                            .accessibilityIdentifier("liveactivity.probe")
                            .accessibilityValue(app.activityClient.summary)
                    }
                }
                // dshm:// is registered only in the Debug Info.plist.
                .onOpenURL { url in
                    if DebugDeepLink.route(url) != nil { app.openPairingCode(url.absoluteString) }
                }
                #endif
        }
        // Refresh on foreground (resume from the cursor); iOS drops sockets in the background.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: app.store?.foreground()
            case .background: app.store?.background()
            default: break
            }
        }
    }

    // The pairing screen replaces the main screen rather than using a sheet: a sheet presented
    // from onOpenURL didn't show up in XCUITest's accessibility tree.
    @ViewBuilder private var root: some View {
        if let route = app.pairingRoute {
            PairingView(route: route) {
                let wasUnpaired = !app.hasSavedHosts
                app.closePairing()
                showFirstTask = wasUnpaired && app.hasSavedHosts
                // After the first pairing, 01 opens with the first task in the composer.
                if showFirstTask, let store = app.store, store.composer.prompt.isEmpty { store.composer.prompt = FirstRun.suggestion }
            }
        } else if let store = app.store {
            ShellView(store: store, showFirstTask: $showFirstTask) { app.startPairing() }
                .id(ObjectIdentifier(store))
        } else if app.hasSavedHosts {
            ContentUnavailableView {
                Label("Couldn't open your paired computers", systemImage: "lock.trianglebadge.exclamationmark")
            } actions: {
                Button("Try again") { app.retrySavedHosts() }
                Button("Pair a computer") { app.startPairing() }
            }
        } else {
            WelcomeView(scan: { app.startPairing() }, paste: { app.startPairing(.paste) })
        }
    }
}
