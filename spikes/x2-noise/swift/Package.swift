// swift-tools-version: 6.2
// X2 spike: Noise on CryptoKit. No dependencies beyond Apple frameworks.
import PackageDescription

let package = Package(
    name: "NoiseKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "NoiseKit", targets: ["NoiseKit"])],
    targets: [
        .target(name: "NoiseKit"),
        .executableTarget(name: "noise-peer", dependencies: ["NoiseKit"]),
        .testTarget(name: "NoiseKitTests", dependencies: ["NoiseKit"]),
    ],
    swiftLanguageModes: [.v6]
)
