#if DEBUG
import SwiftUI

/// Where `dshm://pair?…` lands in Debug builds. A stub until S1 builds real pairing; it only
/// shows the parameters, so UI tests can drive the pairing entry without a camera.
struct PairingLink: Identifiable {
    let id = UUID()
    let parameters: [String: String]
}

struct PairingStubView: View {
    let link: PairingLink
    let close: () -> Void

    var body: some View {
        NavigationStack {
            List(link.parameters.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                LabeledContent(item.key, value: item.value)
            }
            .accessibilityIdentifier("pairing.stub")
            .navigationTitle("Pair (stub)")
            .toolbar {
                Button("Close", action: close).accessibilityIdentifier("pairing.close")
            }
        }
    }
}
#endif
