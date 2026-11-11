import DSHTransport
import Foundation

struct TLSChannel: SecureChannel, FrameCipher {
    let name = "TLS 1.3"
    let path = "/"
    func url(for endpoint: HostEndpoint) -> URL {
        var components = URLComponents(url: endpoint.webSocketURL(path: path), resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        return components.url!
    }
    func validate(_ endpoint: HostEndpoint) throws {}
    func establish(over transport: any BridgeTransport) async throws -> any FrameCipher { self }
    func seal(_ plaintext: Data) -> Data { plaintext }
    func open(_ ciphertext: Data) -> Data { ciphertext }
}

extension HostConnection {
    public init(endpoints: [HostEndpoint], spkiSHA256: Data, authorization: String? = nil,
                onAddressesChange: (@Sendable ([HostEndpoint]) -> Void)? = nil) {
        self.init(endpoints: endpoints, channel: TLSChannel(), transport: { url in
            try WebSocketTransport.pinnedTLS(url: url, spkiSHA256: spkiSHA256, authorization: authorization)
        }, onAddressesChange: onAddressesChange)
    }
}
