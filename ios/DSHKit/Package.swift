// swift-tools-version: 6.2
// DSHKit: everything in the app that isn't a view. See ARCHITECTURE.md D15 (provisional).
import PackageDescription

let package = Package(
    name: "DSHKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DSHKit", targets: ["DSHProtocol", "DSHCore", "DSHTestSupport"]),
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
        // HostConnection, SecureChannel, PlaintextChannel, TaskStore.
        .target(name: "DSHCore", dependencies: ["DSHProtocol"]),
        // FakeBridge and other debug-only test doubles. Compiled out of Release (#if DEBUG).
        .target(name: "DSHTestSupport", dependencies: ["DSHCore", "DSHProtocol"]),
        .testTarget(
            name: "DSHKitTests",
            dependencies: ["DSHCore", "DSHProtocol", "DSHTestSupport"]
        ),
    ]
)
