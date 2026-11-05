import DSHCore
import SwiftUI

@main
struct dsh_mobileApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            root
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
            PairingView(route: route) { app.closePairing() }
        } else if let store = app.store {
            RootView(store: store) { app.showingScanner = true }
                .id(ObjectIdentifier(store))
        } else {
            WelcomeView { app.showingScanner = true }
        }
    }
}

/// Release builds with no paired host: pairing is the only thing to do (STORY principle 6).
struct WelcomeView: View {
    let pair: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Pair with your DSH host").font(.title2.bold())
            Text("On the machine that runs DSH, the dsh-mobile bridge prints a QR code. Scan it to pair; everything between this phone and the host is end-to-end encrypted.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Scan pairing code", action: pair)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pairing.scan")
        }
        .padding(32)
    }
}
