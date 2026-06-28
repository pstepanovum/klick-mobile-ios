import Foundation

enum APIError: Error {
    case server(message: String, status: Int)
    case decoding
    case noData

    /// Human-readable message to show the user.
    var userMessage: String {
        switch self {
        case .server(let message, _): return message
        case .decoding: return "Unexpected response from the server."
        case .noData: return "Couldn’t reach the server. Check your connection."
        }
    }
}

/// Thin async/await REST client for the Klic API. Injects the access token and
/// transparently refreshes it once on a 401.
actor APIClient {
    static let shared = APIClient()

    /// Live server (TLS via sslip.io). For local dev point this at http://localhost:3000/api/v1.
    static let baseURL = URL(string: "https://api.89.34.230.2.sslip.io/api/v1")!

    private let session = URLSession.shared

    /// Coalesces concurrent refreshes so a burst of 401s triggers exactly one
    /// rotation + retry instead of N competing rotations.
    private var refreshTask: Task<Bool, Never>?

    func register(username: String, password: String, displayName: String) async throws -> AuthResponse {
        try await post("/auth/register", body: [
            "username": username, "password": password, "displayName": displayName,
        ], authed: false)
    }

    func login(username: String, password: String) async throws -> AuthResponse {
        try await post("/auth/login", body: ["username": username, "password": password], authed: false)
    }

    func refresh(refreshToken: String) async throws -> AuthResponse {
        try await post("/auth/refresh", body: ["refreshToken": refreshToken], authed: false)
    }

    // MARK: Friends

    func findUser(username: String) async throws -> [User] {
        let q = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username
        return try await get("/users?username=\(q)")
    }

    func friends() async throws -> [User] { try await get("/friends") }

    func friendRequests() async throws -> [FriendRequest] { try await get("/friends/requests") }

    func sendFriendRequest(userId: String) async throws -> EmptyResponse {
        try await post("/friends/requests", body: ["userId": userId])
    }

    func acceptFriendRequest(id: String) async throws -> EmptyResponse {
        try await post("/friends/requests/\(id)/accept", body: [:])
    }

    func declineFriendRequest(id: String) async throws -> EmptyResponse {
        try await post("/friends/requests/\(id)/decline", body: [:])
    }

    func openConversation(userId: String) async throws -> Conversation {
        try await post("/conversations", body: ["userId": userId])
    }

    // MARK: Conversations / messaging

    func conversations() async throws -> [Conversation] { try await get("/conversations") }

    func messages(conversationId: String) async throws -> [Message] {
        try await get("/conversations/\(conversationId)/messages")
    }

    func send(conversationId: String, body: String, replyToId: String? = nil) async throws -> Message {
        var payload: [String: Any] = ["body": body]
        if let replyToId { payload["replyToId"] = replyToId }
        return try await post("/conversations/\(conversationId)/messages", body: payload)
    }

    func sendSticker(conversationId: String, stickerId: String, replyToId: String? = nil) async throws -> Message {
        var payload: [String: Any] = ["stickerId": stickerId]
        if let replyToId { payload["replyToId"] = replyToId }
        return try await post("/conversations/\(conversationId)/messages", body: payload)
    }

    /// Toggle an emoji reaction on a message; returns the message's new aggregate.
    @discardableResult
    func react(conversationId: String, messageId: String, emoji: String) async throws -> [Reaction] {
        struct R: Decodable { let reactions: [Reaction] }
        let r: R = try await post("/conversations/\(conversationId)/messages/\(messageId)/reactions",
                                  body: ["emoji": emoji])
        return r.reactions
    }

    /// Delete a message for everyone (sender-only server-side).
    func deleteForEveryone(conversationId: String, messageId: String) async throws {
        let _: EmptyResponse = try await delete("/conversations/\(conversationId)/messages/\(messageId)?scope=everyone")
    }

    func recentCalls() async throws -> [RecentCall] { try await get("/calls") }

    func stickers() async throws -> [Sticker] {
        struct Catalog: Decodable { let stickers: [Sticker] }
        let catalog: Catalog = try await get("/stickers")
        return catalog.stickers
    }

    func startCall(conversationId: String, kind: String) async throws -> CallSession {
        try await post("/calls", body: ["conversationId": conversationId, "kind": kind])
    }

    func joinToken(callId: String) async throws -> CallSession {
        try await post("/calls/\(callId)/token", body: [:])
    }

    func mediaJoined(callId: String) async throws -> EmptyResponse {
        try await post("/calls/\(callId)/media-joined", body: [:])
    }

    func declineCall(callId: String) async throws -> EmptyResponse {
        try await post("/calls/\(callId)/decline", body: [:])
    }

    func cancelCall(callId: String) async throws -> EmptyResponse {
        try await post("/calls/\(callId)/cancel", body: [:])
    }

    func failCall(callId: String) async throws -> EmptyResponse {
        try await post("/calls/\(callId)/fail", body: [:])
    }

    func endCall(callId: String) async throws -> EmptyResponse {
        try await post("/calls/\(callId)/end", body: [:])
    }

    nonisolated static func mobileDiagnostic(event: String, callId: String? = nil, detail: String? = nil) {
        guard let url = URL(string: baseURL.absoluteString + "/diagnostics/mobile-event") else { return }
        var body: [String: Any] = ["source": "ios", "event": event]
        if let callId { body["callId"] = callId }
        if let detail { body["detail"] = String(detail.prefix(500)) }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req).resume()
    }

    func registerDevice(pushToken: String?, voipToken: String?) async throws -> EmptyResponse {
        var body: [String: Any] = ["platform": "IOS"]
        if let pushToken { body["pushToken"] = pushToken }
        if let voipToken { body["voipToken"] = voipToken }
        return try await post("/me/devices", body: body)
    }

    // MARK: Profile

    /// Update the current user's profile. `username` is immutable server-side.
    func updateProfile(displayName: String? = nil, showLastSeen: Bool? = nil, avatarKey: String?? = nil) async throws -> User {
        var body: [String: Any] = [:]
        if let displayName { body["displayName"] = displayName }
        if let showLastSeen { body["showLastSeen"] = showLastSeen }
        if let avatarKey { body["avatarKey"] = avatarKey ?? NSNull() }  // nil-wrapped clears it
        return try await patch("/me", body: body)
    }

    /// Presign a PUT for a new avatar; upload the bytes via `uploadData`, then PATCH /me with the key.
    func requestAvatarUpload(contentType: String, byteSize: Int) async throws -> UploadTicket {
        try await post("/me/avatar-upload", body: ["contentType": contentType, "byteSize": byteSize])
    }

    /// A friend's profile (avatar, name, presence/last-seen if shared).
    func userProfile(id: String) async throws -> UserProfile {
        try await get("/users/\(id)")
    }

    /// Public, stable avatar URL for any user id (the endpoint 302-redirects to the
    /// presigned image, or 404s — in which case the UI falls back to initials).
    nonisolated static func avatarURL(forUserId id: String) -> String {
        baseURL.absoluteString + "/users/\(id)/avatar"
    }

    // MARK: Attachments / media

    /// Step 1: ask the server for a presigned PUT URL for an attachment.
    func requestUpload(conversationId: String, kind: String, contentType: String, byteSize: Int) async throws -> UploadTicket {
        try await post("/uploads", body: [
            "conversationId": conversationId, "kind": kind, "contentType": contentType, "byteSize": byteSize,
        ])
    }

    /// Step 2: PUT the bytes straight to object storage. No auth header; the
    /// Content-Type MUST equal what `requestUpload` was given or the URL's signature fails.
    func uploadData(_ data: Data, to uploadUrl: String, contentType: String) async throws {
        guard let url = URL(string: uploadUrl) else { throw APIError.noData }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await session.upload(for: req, from: data)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(message: "Upload failed", status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Step 3: send the message referencing the uploaded object key(s).
    func sendMessage(conversationId: String, body: String?, attachments: [AttachmentDraft], replyToId: String? = nil) async throws -> Message {
        var payload: [String: Any] = [:]
        if let body, !body.isEmpty { payload["body"] = body }
        if let replyToId { payload["replyToId"] = replyToId }
        payload["attachments"] = attachments.map { a -> [String: Any] in
            var d: [String: Any] = ["key": a.key, "kind": a.kind, "contentType": a.contentType, "byteSize": a.byteSize]
            if let w = a.width { d["width"] = w }
            if let h = a.height { d["height"] = h }
            if let ms = a.durationMs { d["durationMs"] = ms }
            if let wf = a.waveform { d["waveform"] = wf.base64EncodedString() }
            if let n = a.fileName { d["fileName"] = n }
            return d
        }
        return try await post("/conversations/\(conversationId)/messages", body: payload)
    }

    /// Re-presign a download URL when an old attachment's link has expired.
    func refreshAttachmentURL(id: String) async throws -> String {
        struct R: Decodable { let url: String }
        let r: R = try await get("/attachments/\(id)/url")
        return r.url
    }

    // MARK: - Core

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await request(path, method: "GET", body: nil, authed: true)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], authed: Bool = true) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await request(path, method: "POST", body: data, authed: authed)
    }

    private func patch<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await request(path, method: "PATCH", body: data, authed: true)
    }

    private func delete<T: Decodable>(_ path: String) async throws -> T {
        try await request(path, method: "DELETE", body: nil, authed: true)
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String,
        body: Data?,
        authed: Bool,
        hasRetriedAuth: Bool = false
    ) async throws -> T {
        // Concatenate so query strings (`?username=…`) are preserved — appendingPathComponent
        // would percent-encode the `?` into the path and 404 the route.
        guard let url = URL(string: Self.baseURL.absoluteString + path) else { throw APIError.noData }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authed, let token = await validAccessToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (respData, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.noData }
        if authed, http.statusCode == 401, !hasRetriedAuth, await refreshAccessToken() {
            return try await request(
                path,
                method: method,
                body: body,
                authed: authed,
                hasRetriedAuth: true
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(message: Self.message(from: respData, status: http.statusCode), status: http.statusCode)
        }

        if respData.isEmpty, let empty = EmptyResponse() as? T { return empty }
        do { return try JSONDecoder().decode(T.self, from: respData) }
        catch { throw APIError.decoding }
    }

    /// Turn the server's error body into a readable sentence
    /// (`{error,issues:[{message}]}` for validation, or `{message}` otherwise).
    private static func message(from data: Data, status: Int) -> String {
        struct Issue: Decodable { let message: String }
        struct Body: Decodable { let message: String?; let issues: [Issue]? }
        if let body = try? JSONDecoder().decode(Body.self, from: data) {
            if let first = body.issues?.first { return first.message }
            if let message = body.message { return message }
        }
        return "Request failed (\(status))."
    }

    /// A non-expired access token, refreshing first if the current one is missing or
    /// stale. Returns whatever token we hold afterwards (nil only if refresh failed).
    private func validAccessToken() async -> String? {
        if !AccessToken.isExpired(TokenStore.accessToken) { return TokenStore.accessToken }
        if TokenStore.refreshToken != nil { _ = await refreshAccessToken() }
        return TokenStore.accessToken
    }

    /// Exchange the refresh token for a fresh access token, at most one in flight, so a
    /// burst of expired requests triggers a single rotation. Returns `true` if we hold
    /// a valid access token afterwards.
    ///
    /// A `401` means the refresh token is genuinely dead → clear it and broadcast a
    /// sign-out. Any other failure (network/5xx/timeout) is transient: keep the tokens
    /// so the user stays signed in and we retry later.
    @discardableResult
    func refreshAccessToken() async -> Bool {
        if let inFlight = refreshTask { return await inFlight.value }
        let task = Task<Bool, Never> { await self.performRefresh() }
        refreshTask = task
        let ok = await task.value
        refreshTask = nil
        return ok
    }

    private func performRefresh() async -> Bool {
        guard let refreshToken = TokenStore.refreshToken else { return false }
        do {
            let res = try await refresh(refreshToken: refreshToken)
            TokenStore.save(access: res.accessToken, refresh: res.refreshToken)
            return true
        } catch let APIError.server(_, status) where status == 401 {
            TokenStore.clear()
            await MainActor.run { NotificationCenter.default.post(name: .klicSessionExpired, object: nil) }
            return false
        } catch {
            return false
        }
    }
}

struct EmptyResponse: Decodable {}
