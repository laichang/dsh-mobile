import Foundation
import DSHTransport
import Synchronization

/// Where the phone's Noise static key (X25519) lives (ARCHITECTURE §4 "Keys"). One key per
/// device, shared by every paired host; the bridge registers its public half.
public protocol DeviceKeyStore: Sendable {
    /// The device's static key, created on first use.
    func identity() throws -> NoiseKeyPair
    /// Forgets the key (Debug reset; a later "unpair everything").
    func reset() throws
}

public typealias DeviceKeyStoreError = KeychainDataError

/// Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: never synced, never in backups,
/// readable after the first unlock so a foreground reconnect never waits for Face ID.
public struct KeychainDeviceKeyStore: DeviceKeyStore {
    public let service: String
    public let account: String

    public init(service: String = "chang.dsh-mobile.noise", account: String = "device-static-x25519") {
        self.service = service
        self.account = account
    }

    private var item: KeychainData { KeychainData(service: service, account: account) }

    public func identity() throws -> NoiseKeyPair {
        let bytes = try item.readOrCreate { Data(NoiseKeyPair().privateKeyBytes) }
        return try NoiseKeyPair(privateKey: Array(bytes))
    }

    public func reset() throws { try item.reset() }
}

/// For tests and previews.
public final class InMemoryDeviceKeyStore: DeviceKeyStore {
    private let key: Mutex<NoiseKeyPair?>

    public init(_ key: NoiseKeyPair? = nil) { self.key = Mutex(key) }

    public func identity() throws -> NoiseKeyPair {
        key.withLock { k in
            if let k { return k }
            let new = NoiseKeyPair()
            k = new
            return new
        }
    }

    public func reset() throws { key.withLock { $0 = nil } }
}
