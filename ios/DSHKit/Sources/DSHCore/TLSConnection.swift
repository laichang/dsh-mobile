import Foundation

extension HostConnection {
    public init(endpoints: [HostEndpoint], spkiSHA256: Data, authorization: String? = nil,
                onAddressesChange: (@Sendable ([HostEndpoint]) -> Void)? = nil) {
        self.init(endpoints: endpoints, channelName: "TLS 1.3", transport: { url in
            try WebSocketTransport.pinnedTLS(url: url, spkiSHA256: spkiSHA256, authorization: authorization)
        }, onAddressesChange: onAddressesChange)
    }
}
