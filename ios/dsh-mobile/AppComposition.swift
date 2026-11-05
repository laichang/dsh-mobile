import DSHCore
import Foundation
import SwiftData
#if DEBUG
import DSHTestSupport
#endif

/// Builds the object graph. One host so far: the bridge on this Mac's loopback, plaintext (T0),
/// with the durable task cache and resume (S2). S1 / S9 replace the hardcoded host with paired ones.
enum AppComposition {
    static func makeStore() -> TaskListStore {
        var endpoint = HostEndpoint.localBridge()
        var transport: BridgeTransportFactory = WebSocketTransport.factory
        var keyPrefix = "bridge"
        var prompt = ""
        var connectDelay: Duration = .zero
        var resetStore = false
        #if DEBUG
        let options = DebugLaunchOptions.parse(ProcessInfo.processInfo.arguments)
        if let port = options.bridgePort { endpoint = .localBridge(port: port) }
        if options.useFakeBridge {
            transport = FakeHost(reachable: !options.fakeBridgeOffline).factory
            keyPrefix = "fake"
        }
        prompt = options.presetPrompt ?? ""
        if let seconds = options.connectDelay { connectDelay = .milliseconds(Int(seconds * 1000)) }
        resetStore = options.resetStore
        #endif
        let container = makeContainer()
        if resetStore { try? TaskCache.erase(container) }
        let connection = HostConnection(endpoint: endpoint, channel: PlaintextChannel(), transport: transport)
        return TaskListStore(
            container: container,
            hosts: [.init(key: "\(keyPrefix):\(endpoint)", connection: connection)],
            prompt: prompt, firstConnectDelay: connectDelay)
    }

    /// The cache on disk; if it can't be opened (e.g. an incompatible schema in a dev build),
    /// start from an empty one rather than not at all. The host is the source of truth (D9).
    private static func makeContainer() -> ModelContainer {
        if let container = try? TaskCache.container() { return container }
        let url = URL.applicationSupportDirectory.appending(path: "default.store")
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(filePath: url.path() + suffix))
        }
        if let container = try? TaskCache.container() { return container }
        return try! TaskCache.container(inMemory: true)
    }
}
