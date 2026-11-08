// swift-tools-version: 6.2
// DSHKit: everything in the app that isn't a view. See ARCHITECTURE.md D15 (provisional).
import PackageDescription

let package = Package(
    name: "DSHKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "DSHKit", targets: ["DSHProtocol", "DSHCore", "DSHTestSupport", "DSHActivity"]),
        // The Live Activity's data, shared by the app and its widget extension (D119). No dependencies,
        // so the extension stays small.
        .library(name: "DSHActivity", targets: ["DSHActivity"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
    ],
    targets: [
        // Generated from protocol/*.proto by scripts/codegen. Don't edit by hand.
        .target(
            name: "DSHProtocol",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        // TaskActivityState, and TaskActivityAttributes where ActivityKit exists.
        .target(name: "DSHActivity"),
        // HostConnection, SecureChannel, PlaintextChannel, TaskStore.
        .target(name: "DSHCore", dependencies: ["DSHProtocol", "DSHActivity"]),
        // FakeBridge and other debug-only test doubles. Compiled out of Release (#if DEBUG).
        .target(name: "DSHTestSupport", dependencies: ["DSHCore", "DSHProtocol"]),
        .testTarget(
            name: "DSHKitTests",
            dependencies: ["DSHCore", "DSHProtocol", "DSHTestSupport", "DSHActivity"]
        ),
    ]
)
