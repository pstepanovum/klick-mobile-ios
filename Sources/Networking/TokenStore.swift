import Foundation
import Security

/// Stores access + refresh tokens in the Keychain.
enum TokenStore {
    private static let service = "com.klic.mobile.app.tokens"
    private static let accessKey = "access"
    private static let refreshKey = "refresh"

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

    // MARK: - Keychain primitives

    private static func write(_ key: String, _ value: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            // Readable after the first unlock so background/VoIP-push wakeups (and a
            // locked device) can still load the token to refresh and place calls.
            // ThisDeviceOnly: tokens never leave in backups/transfers — a restored
            // install re-authenticates instead of inheriting another device's session.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
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
