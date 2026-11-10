import SwiftUI
import Vision
import VisionKit

/// Scans the host's pairing QR with the camera (VisionKit's DataScanner). Where the camera
/// isn't available (Simulator, no permission) it falls back to pasting the `dshm://pair?…`
/// link the host's terminal prints next to the QR.
/// 08 opens it for scanning or for pasting (`Mode.paste`: no camera, the link field has focus).
struct ScannerView: View {
    enum Mode { case scan, paste }

    var mode: Mode = .scan
    let found: (String) -> Void
    let cancel: () -> Void
    @State private var pasted = ""
    @FocusState private var linkFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("On your computer, find the pairing code in the terminal where DSH started. Keep your phone on the same Wi-Fi or connect through a private network such as Tailscale.")
                        .accessibilityIdentifier("pairing.guide")
                    if mode == .paste {
                        EmptyView()
                    } else if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                        QRScanner(found: found)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .frame(height: 240)
                        Text("Point the camera at the pairing code.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Label("Camera unavailable. Use the link printed under the code.", systemImage: "camera.slash")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("Paste the pairing link", text: $pasted)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($linkFocused)
                            .accessibilityIdentifier("pairing.paste")
                        Button("Use") { found(pasted) }
                            .disabled(pasted.isEmpty)
                            .accessibilityIdentifier("pairing.pasteUse")
                    }
                    DisclosureGroup("Need a pairing code?") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("For a fresh code, run this command from the dsh-mobile project folder on your computer.")
                            Text(verbatim: "node bridge/lib/scripts/pair.js")
                                .font(.footnote.monospaced()).textSelection(.enabled)
                            Link("Bridge setup instructions", destination: URL(string: "https://github.com/laichang/dsh-mobile/blob/main/bridge/README.md")!)
                                .accessibilityIdentifier("pairing.setupInstructions")
                        }
                        .font(.footnote)
                        .padding(.top, 6)
                    }
                }
                .padding()
            }
            .scrollContentBackground(.hidden)
            .background(DSHTheme.canvas.ignoresSafeArea())
            .onAppear { if mode == .paste { linkFocused = true } }
            .navigationTitle(mode == .paste ? String(localized: "Paste a pairing link", table: "FirstRun") : String(localized: "Pair a computer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
            }
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                guard !done, case .barcode(let code) = item, let payload = code.payloadStringValue,
                      payload.hasPrefix("dshm://pair?") else { continue }
                done = true
                scanner.stopScanning()
                found(payload)
            }
        }
    }
}
