import CryptoKit
import Foundation
import Security

/// One private session per connection. Its trust anchor and credentials never cross host boundaries.
private final class PinnedServer: NSObject, URLSessionTaskDelegate {
    let pin: Data
    let host: String
    init(pin: Data, host: String) { self.pin = pin; self.host = host }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first, accepts(leaf, trust: trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func accepts(_ leaf: SecCertificate, trust: SecTrust) -> Bool {
        guard let key = SecCertificateCopyKey(leaf),
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: point),
              Data(SHA256.hash(data: publicKey.derRepresentation)) == pin,
              let start = SecCertificateCopyNotValidBeforeDate(leaf) as Date?, start <= .now,
              let end = SecCertificateCopyNotValidAfterDate(leaf) as Date?, end > .now else { return false }
        return SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess
            && SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess
            && SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
            && SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess
            && SecTrustEvaluateWithError(trust, nil)
    }
}

extension WebSocketTransport {
    public static func pinnedTLS(url: URL, spkiSHA256: Data, authorization: String? = nil) throws -> WebSocketTransport {
        guard url.scheme == "wss", let host = url.host(percentEncoded: false),
              url.user == nil, url.password == nil, spkiSHA256.count == 32 else { throw URLError(.badURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        configuration.tlsMaximumSupportedProtocolVersion = .TLSv13
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration,
                                 delegate: PinnedServer(pin: spkiSHA256, host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))),
                                 delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return WebSocketTransport(request: request, ownedSession: session)
    }
}
