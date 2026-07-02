import Foundation
import Security

/// Stores access + refresh tokens in the Keychain.
enum TokenStore {
    private static let service = "com.klic.mobile.app.tokens"
    private static let accessKey = "access"
    private static let refreshKey = "refresh"

    /// App-group keychain access group shared with the KlicShare extension (an app group
    /// listed in com.apple.security.application-groups is automatically a keychain access
    /// group on iOS). Writing tokens into it is what lets the share extension authenticate.
    /// Re-signed builds (AltStore) can lose the app-group entitlement, so every write falls
    /// back to the app's private keychain when the group is unavailable — the app keeps
    /// working and only the extension degrades (it shows "Open Klic and sign in first").
    static let sharedAccessGroup = "group.com.klic.mobile.app"

    static var accessToken: String? { read(accessKey) }
    static var refreshToken: String? { read(refreshKey) }

    /// We have stored credentials worth trying to restore a session from.
    static var hasSession: Bool { refreshToken != nil }

    static func save(access: String, refresh: String) {
        write(accessKey, access)
        write(refreshKey, refresh)
    }

    static func clear() {
        delete(accessKey)
        delete(refreshKey)
    }

    /// Move tokens written before keychain sharing existed (app-private access group) into
    /// the shared group so the share extension can read them. No-op once migrated, or when
    /// the app-group entitlement is unavailable (re-signed build) — write() falls back.
    static func migrateToSharedGroupIfNeeded() {
        for key in [accessKey, refreshKey] {
            guard let value = read(key), !isInSharedGroup(key) else { continue }
            write(key, value)
        }
    }

    private static func isInSharedGroup(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: sharedAccessGroup,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Keychain primitives

    private static func write(_ key: String, _ value: String) {
        delete(key)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            // Readable after the first unlock so background/VoIP-push wakeups (and a
            // locked device) can still load the token to refresh and place calls.
            // ThisDeviceOnly: tokens never leave in backups/transfers — a restored
            // install re-authenticates instead of inheriting another device's session.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            // Shared with the KlicShare extension via the app group.
            kSecAttrAccessGroup as String: sharedAccessGroup,
        ]
        if SecItemAdd(query as CFDictionary, nil) != errSecSuccess {
            // errSecMissingEntitlement on builds re-signed without the app group
            // (AltStore) — fall back to the app-private keychain so sign-in still works.
            query.removeValue(forKey: kSecAttrAccessGroup as String)
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    // Reads and deletes deliberately omit kSecAttrAccessGroup: without it the query spans
    // every access group this process can reach (private + shared), so both pre-migration
    // and shared-group tokens are found, from the app and the extension alike.
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

/// Lightweight inspection of the access-token JWT so the client can tell whether a
/// proactive refresh is actually needed — avoiding a token rotation on every launch.
enum AccessToken {
    /// True when there is no token, it can't be parsed, or it expires within `leeway`.
    static func isExpired(_ token: String?, leeway: TimeInterval = 30) -> Bool {
        guard let exp = expiry(of: token) else { return true }
        return exp.timeIntervalSinceNow <= leeway
    }

    static func expiry(of token: String?) -> Date? {
        claims(of: token).flatMap { ($0["exp"] as? Double).map { Date(timeIntervalSince1970: $0) } }
    }

    /// The `sub` claim (user id) of the current/given access token.
    static func subject(of token: String?) -> String? {
        claims(of: token)?["sub"] as? String
    }

    private static func claims(of token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = base64urlDecode(String(parts[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str += "=" }
        return Data(base64Encoded: str)
    }
}

extension Notification.Name {
    /// Posted when the refresh token is rejected by the server (a genuine sign-out,
    /// not a transient network error). `AppSession` listens and clears the UI.
    static let klicSessionExpired = Notification.Name("klic.sessionExpired")
}
