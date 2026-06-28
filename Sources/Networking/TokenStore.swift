import Foundation
import Security

/// Stores access + refresh tokens in the Keychain.
enum TokenStore {
    private static let service = "com.klic.app.tokens"
    private static let accessKey = "access"
    private static let refreshKey = "refresh"

    static var accessToken: String? { read(accessKey) }
    static var refreshToken: String? { read(refreshKey) }

    static func save(access: String, refresh: String) {
        write(accessKey, access)
        write(refreshKey, refresh)
    }

    static func clear() {
        delete(accessKey)
        delete(refreshKey)
    }

    // MARK: - Keychain primitives

    private static func write(_ key: String, _ value: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
