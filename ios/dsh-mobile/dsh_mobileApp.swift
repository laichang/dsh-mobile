import DSHCore
import SwiftUI

@main
struct dsh_mobileApp: App {
    @State private var store = AppComposition.makeStore()
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
                    ContentView(store: store)
                }
            }
            .onOpenURL { url in
                if case .pair(let parameters) = DebugDeepLink.route(url) {
                    pairingLink = PairingLink(parameters: parameters)
                }
            }
            #else
            ContentView(store: store)
            #endif
        }
    }
}
