import Foundation
import Security

/// Holds one pairing as a single Keychain item so the unlock code and
/// its counter cannot be loaded from different versions of the pairing.
enum Libre2CredentialsStore {
    enum StoreError: Error {
        case invalidCredentials
        case unexpectedStatus(OSStatus)
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "de.poeml.philipp.LibreWrist",
            kSecAttrAccount as String: "libre2.ble.pairing"
        ]
    }

    static func read() throws -> Libre2Pairing.Credentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw StoreError.invalidCredentials }
        let credentials = try JSONDecoder().decode(Libre2Pairing.Credentials.self, from: data)
        guard credentials.isValid else { throw StoreError.invalidCredentials }
        return credentials
    }

    static func save(_ credentials: Libre2Pairing.Credentials) throws {
        guard credentials.isValid else { throw StoreError.invalidCredentials }
        let data = try JSONEncoder().encode(credentials)
        let update = [kSecValueData as String: data] as CFDictionary
        let existing = SecItemUpdate(query as CFDictionary, update)
        if existing == errSecSuccess { return }
        guard existing == errSecItemNotFound else { throw StoreError.unexpectedStatus(existing) }

        var request = query
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(request as CFDictionary, nil)
        let status = added == errSecDuplicateItem ? SecItemUpdate(query as CFDictionary, update) : added
        guard status == errSecSuccess else { throw StoreError.unexpectedStatus(status) }
    }
}
