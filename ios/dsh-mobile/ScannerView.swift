import SwiftUI
import Vision
import VisionKit

/// Scans the host's pairing QR with the camera (VisionKit's DataScanner). Where the camera
/// isn't available (Simulator, no permission) it falls back to pasting the `dshm://pair?…`
/// link the host's terminal prints next to the QR.
struct ScannerView: View {
    let found: (String) -> Void
    let cancel: () -> Void
    @State private var pasted = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    QRScanner(found: found)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .frame(maxHeight: 420)
                    Text("Point the camera at the QR code your DSH host shows (run `node bridge/lib/scripts/pair.js` on the host for a new one).")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Label("The camera isn't available here.", systemImage: "camera.slash")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    TextField("or paste the dshm://pair link", text: $pasted)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("pairing.paste")
                    Button("Use") { found(pasted) }
                        .disabled(pasted.isEmpty)
                        .accessibilityIdentifier("pairing.pasteUse")
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Scan pairing code")
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
