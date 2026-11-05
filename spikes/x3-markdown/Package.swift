// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StreamingBenchmark",
    platforms: [.iOS(.v26), .macOS(.v15)],
    targets: [.testTarget(name: "StreamingTests")]
)
