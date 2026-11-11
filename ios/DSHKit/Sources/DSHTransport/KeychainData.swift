import Foundation
import Security

public enum KeychainDataError: Error, Equatable {
    case keychain(OSStatus)
}

public struct KeychainData: Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainDataError.keychain(status) }
        guard let bytes = item as? Data else { throw KeychainDataError.keychain(errSecDecode) }
        return bytes
    }

    public func readOrCreate(_ create: () throws -> Data) throws -> Data {
        if let existing = try read() { return existing }
        let bytes = try create()
        var add = query
        add[kSecValueData as String] = bytes
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try read() { return existing }
        guard status == errSecSuccess else { throw KeychainDataError.keychain(status) }
        return bytes
    }

    public func reset() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainDataError.keychain(status) }
    }
}
