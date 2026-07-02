import Foundation

/// Minimal REST client for the share extension. The app's full APIClient drags in the
/// E2EE/libsignal stack, so the extension compiles only TokenStore + AppConfig and talks
/// to the handful of endpoints sharing needs: friends, open conversation, presigned
/// upload, send message. Auth mirrors APIClient: bearer token, one refresh on a 401.
final class ShareAPI {
    static let shared = ShareAPI()

    struct Friend: Decodable, Identifiable, Hashable {
        let id: String
        let username: String
        let displayName: String
        var avatarUrl: String?
    }

    enum ShareAPIError: LocalizedError {
        case notSignedIn
        case server(String, Int)
        case network

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Open Klic and sign in first."
            case .server(let message, _): return message
            case .network: return "Couldn’t reach the server. Check your connection."
            }
        }
    }

    private let session = URLSession.shared
    private let baseURL = AppConfig.apiBaseURL

    func friends() async throws -> [Friend] {
        try await request("GET", "/friends")
    }

    /// Open (or reuse) the direct conversation with a friend; returns its id.
    func openConversation(userId: String) async throws -> String {
        struct Ref: Decodable { let id: String }
        let ref: Ref = try await request("POST", "/conversations", body: ["userId": userId])
        return ref.id
    }

    /// Upload every media item into the conversation via the presigned-PUT flow, then send
    /// a single message carrying all attachments plus the optional text.
    func sendShare(conversationId: String, text: String?, media: [SharePayloadItem]) async throws {
        struct Ticket: Decodable { let key: String; let uploadUrl: String }

        var attachments: [[String: Any]] = []
        for item in media {
            let ticket: Ticket = try await request("POST", "/uploads", body: [
                "conversationId": conversationId,
                "kind": item.kind,
                "contentType": item.contentType,
                "byteSize": item.data.count,
            ])
            try await upload(item.data, to: ticket.uploadUrl, contentType: item.contentType)
            var d: [String: Any] = [
                "key": ticket.key, "kind": item.kind,
                "contentType": item.contentType, "byteSize": item.data.count,
            ]
            if let w = item.width { d["width"] = w }
            if let h = item.height { d["height"] = h }
            if let ms = item.durationMs { d["durationMs"] = ms }
            if let n = item.fileName { d["fileName"] = n }
            attachments.append(d)
        }

        var payload: [String: Any] = [:]
        if let text, !text.isEmpty { payload["body"] = text }
        if !attachments.isEmpty { payload["attachments"] = attachments }
        let _: IgnoredResponse = try await request(
            "POST", "/conversations/\(conversationId)/messages", body: payload
        )
    }

    // MARK: - Core

    /// Decodes successfully no matter what the server returns (we don't render the
    /// created message in the extension).
    private struct IgnoredResponse: Decodable {
        init() {}
        init(from decoder: Decoder) throws {}
    }

    private func upload(_ data: Data, to uploadUrl: String, contentType: String) async throws {
        guard let url = URL(string: uploadUrl) else { throw ShareAPIError.network }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        // Content-Type MUST match what /uploads was given or the presigned signature fails.
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await session.upload(for: req, from: data)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ShareAPIError.server("Upload failed", (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func request<T: Decodable>(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil,
        hasRetriedAuth: Bool = false
    ) async throws -> T {
        guard let url = URL(string: baseURL.absoluteString + path) else { throw ShareAPIError.network }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let token = await validAccessToken() else { throw ShareAPIError.notSignedIn }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw ShareAPIError.network
        }
        guard let http = resp as? HTTPURLResponse else { throw ShareAPIError.network }
        if http.statusCode == 401, !hasRetriedAuth, await refreshAccessToken() {
            return try await request(method, path, body: body, hasRetriedAuth: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ShareAPIError.notSignedIn }
            throw ShareAPIError.server(Self.message(from: data, status: http.statusCode), http.statusCode)
        }
        if data.isEmpty, let empty = IgnoredResponse() as? T { return empty }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ShareAPIError.server("Unexpected response from the server.", http.statusCode) }
    }

    private static func message(from data: Data, status: Int) -> String {
        struct Body: Decodable { let message: String? }
        if let message = (try? JSONDecoder().decode(Body.self, from: data))?.message { return message }
        return "Request failed (\(status))."
    }

    private func validAccessToken() async -> String? {
        if !AccessToken.isExpired(TokenStore.accessToken) { return TokenStore.accessToken }
        _ = await refreshAccessToken()
        return TokenStore.accessToken
    }

    /// Rotate the tokens through the shared Keychain so the app and the extension always
    /// hold the same pair. A failed refresh NEVER clears tokens from the extension — the
    /// user just sees the sign-in hint and the main app decides about real sign-outs.
    private func refreshAccessToken() async -> Bool {
        guard let refreshToken = TokenStore.refreshToken else { return false }
        struct Tokens: Decodable { let accessToken: String; let refreshToken: String }
        guard let url = URL(string: baseURL.absoluteString + "/auth/refresh") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else { return false }
        TokenStore.save(access: tokens.accessToken, refresh: tokens.refreshToken)
        return true
    }
}
