import CryptoKit
import Foundation
import Security

/// Encrypted-at-rest storage for the E2EE key state: one AES-GCM-sealed file in
/// Application Support, keyed by a symmetric key that lives in the Keychain
/// (this-device-only, so neither the file nor the key ever leaves in a backup).
/// The file itself is additionally excluded from backups.
enum E2eeVault {
    private static let service = "com.klic.mobile.app.e2ee"
    private static let account = "vault-key"
    private static let fileName = "klic-e2ee.sealed"

    static func load<T: Decodable>(_ type: T.Type) -> T? {
        guard let key = existingKey(),
              let sealed = try? Data(contentsOf: fileURL()),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key)
        else { return nil } // no state yet, or the Keychain key is gone → start over
        return try? JSONDecoder().decode(T.self, from: plain)
    }

    static func save<T: Encodable>(_ value: T) throws {
        let plain = try JSONEncoder().encode(value)
        let sealed = try AES.GCM.seal(plain, using: loadOrCreateKey()).combined!
        var url = fileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    static func destroy() {
        try? FileManager.default.removeItem(at: fileURL())
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    // MARK: - Key handling

    private static func fileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    private static func existingKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    private static func loadOrCreateKey() -> SymmetricKey {
        if let key = existingKey() { return key }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Readable after first unlock (background key upkeep), never leaves the device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(add as CFDictionary, nil)
        return key
    }
}
