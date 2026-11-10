import Foundation
import Security
import Synchronization

/// Where the phone's Noise static key (X25519) lives (ARCHITECTURE §4 "Keys"). One key per
/// device, shared by every paired host; the bridge registers its public half.
public protocol DeviceKeyStore: Sendable {
    /// The device's static key, created on first use.
    func identity() throws -> NoiseKeyPair
    /// Forgets the key (Debug reset; a later "unpair everything").
    func reset() throws
}

public enum DeviceKeyStoreError: Error, Equatable {
    case keychain(OSStatus)
}

/// Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: never synced, never in backups,
/// readable after the first unlock so a foreground reconnect never waits for Face ID.
public struct KeychainDeviceKeyStore: DeviceKeyStore {
    public let service: String
    public let account: String

    public init(service: String = "chang.dsh-mobile.noise", account: String = "device-static-x25519") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func identity() throws -> NoiseKeyPair {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return try NoiseKeyPair(privateKey: Array(data))
        }
        guard status == errSecItemNotFound else { throw DeviceKeyStoreError.keychain(status) }
        let key = NoiseKeyPair()
        var add = query
        add[kSecValueData as String] = Data(key.privateKeyBytes)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw DeviceKeyStoreError.keychain(added) }
        return key
    }

    public func reset() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceKeyStoreError.keychain(status) }
    }
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
