import Foundation

extension URL {
    func withScheme(_ scheme: String) -> URL {
        var parts = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        parts.scheme = scheme
        return parts.url!
    }
}

extension Pairing {
    static func credential(_ deviceID: String) -> KeychainData {
        .init(service: "dsh-mobile.tls-device", account: deviceID)
    }

    public static func removeCredential(for host: PairedHost) throws {
        if let id = host.tlsDeviceID { try credential(id).reset() }
    }

    func enroll(_ offer: PairingOffer) async throws -> PairedHost {
        struct Enrollment: Decodable { let id: UUID; let bearer: String }
        func encoded(_ value: [UInt8]) -> String {
            Data(value).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        var failures: [String] = []
        for endpoint in offer.addresses {
            var request = URLRequest(url: endpoint.webSocketURL(path: "/enroll").withScheme("https"))
            request.httpMethod = "POST"
            request.setValue("Offer " + encoded(offer.offerID) + "." + encoded(offer.secret), forHTTPHeaderField: "Authorization")
            let data: Data, status: HTTPURLResponse
            do { (data, status) = try await WebSocketTransport.pinnedRequest(request, spkiSHA256: Data(offer.hostKey)) }
            catch {
                try Task.checkCancellation()
                failures.append(AddressFailure(endpoint: endpoint, error: error).description)
                continue
            }
            guard status.statusCode == 201, let entry = try? JSONDecoder().decode(Enrollment.self, from: data),
                  entry.bearer.count == 43, PairingOffer.base64URLDecode(entry.bearer)?.count == 32 else {
                throw PairingError.unreachable(["host refused the enrollment offer"])
            }
            var host = PairedHost(name: offer.hostName, addresses: [endpoint] + offer.addresses.filter { $0 != endpoint },
                                  hostKey: offer.hostKey, pairedAt: now())
            let deviceID = entry.id.uuidString.lowercased()
            host.tlsDeviceID = deviceID
            let previous = hosts.load().first { $0.id == host.id }
            let key = Self.credential(deviceID)
            _ = try key.readOrCreate { Data(entry.bearer.utf8) }
            do { try hosts.save(host) }
            catch { try? key.reset(); throw error }
            if let previous, previous.tlsDeviceID != deviceID { try? Self.removeCredential(for: previous) }
            return host
        }
        throw PairingError.unreachable(failures)
    }
}
