import DSHCore
import SwiftUI

@main
struct dsh_mobileApp: App {
    @State private var store = AppComposition.makeStore()
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @State private var pairingLink: PairingLink?
    #endif

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            Group {
                // The stub replaces the screen rather than using a sheet, so XCUITest sees it.
                if let link = pairingLink {
                    PairingStubView(link: link) { pairingLink = nil }
                } else {
                    RootView(store: store)
                }
            }
            .onOpenURL { url in
                if case .pair(let parameters) = DebugDeepLink.route(url) {
                    pairingLink = PairingLink(parameters: parameters)
                }
            }
            #else
            RootView(store: store)
            #endif
        }
        // S2: refresh on foreground (resume from the cursor); iOS drops sockets in the background.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: store.foreground()
            case .background: store.background()
            default: break
            }
        }
    }
}
