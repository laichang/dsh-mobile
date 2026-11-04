import DSHCore
import Foundation
#if DEBUG
import DSHTestSupport
#endif

/// Builds the object graph. T0: one host, the bridge on this Mac's loopback, plaintext.
enum AppComposition {
    static func makeStore() -> TaskStore {
        var endpoint = HostEndpoint.localBridge()
        var transport: BridgeTransportFactory = WebSocketTransport.factory
        var prompt = ""
        #if DEBUG
        let options = DebugLaunchOptions.parse(ProcessInfo.processInfo.arguments)
        if options.useFakeBridge { transport = FakeBridge.factory() }
        if let port = options.bridgePort { endpoint = .localBridge(port: port) }
        prompt = options.presetPrompt ?? ""
        #endif
        let connection = HostConnection(endpoint: endpoint, channel: PlaintextChannel(), transport: transport)
        return TaskStore(connection: connection, prompt: prompt)
    }
}
