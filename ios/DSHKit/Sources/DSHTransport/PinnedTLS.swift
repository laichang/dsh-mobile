import CryptoKit
import Foundation
import Security
import Synchronization

/// One private session per connection. Its trust anchor and credentials never cross host boundaries.
private final class PinnedServer: NSObject, URLSessionTaskDelegate {
    let rejectedIdentity = Mutex(false)
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
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                rejectedIdentity.withLock { $0 = true }
            }
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
    private static func session(for url: URL, pin: Data) throws -> URLSession {
        guard let host = url.host(percentEncoded: false), url.user == nil, url.password == nil,
              pin.count == 32 else { throw URLError(.badURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        configuration.tlsMaximumSupportedProtocolVersion = .TLSv13
        configuration.timeoutIntervalForRequest = 10
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration,
                                 delegate: PinnedServer(pin: pin, host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))),
                                 delegateQueue: nil)
    }

    public static func pinnedRequest(_ request: URLRequest, spkiSHA256: Data) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https" else { throw URLError(.badURL) }
        let session = try session(for: url, pin: spkiSHA256)
        defer { session.finishTasksAndInvalidate() }
        let bytes: Data, response: URLResponse
        do { (bytes, response) = try await session.data(for: request) }
        catch {
            if (session.delegate as? PinnedServer)?.rejectedIdentity.withLock({ $0 }) == true {
                throw URLError(.serverCertificateUntrusted)
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse, http.url == url else { throw URLError(.badServerResponse) }
        return (bytes, http)
    }

    public static func pinnedTLS(url: URL, spkiSHA256: Data, authorization: String? = nil) throws -> WebSocketTransport {
        guard url.scheme == "wss" else { throw URLError(.badURL) }
        let session = try session(for: url, pin: spkiSHA256)
        var request = URLRequest(url: url)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return WebSocketTransport(request: request, ownedSession: session)
    }
}
