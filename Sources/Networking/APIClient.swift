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

    func send(conversationId: String, body: String) async throws -> Message {
        try await post("/conversations/\(conversationId)/messages", body: ["body": body])
    }

    func startCall(conversationId: String, kind: String) async throws -> CallSession {
        try await post("/calls", body: ["conversationId": conversationId, "kind": kind])
    }

    func joinToken(callId: String) async throws -> CallSession {
        try await post("/calls/\(callId)/token", body: [:])
    }

    func endCall(callId: String) async throws -> EmptyResponse {
        try await post("/calls/\(callId)/end", body: [:])
    }

    func registerDevice(pushToken: String?, voipToken: String?) async throws -> EmptyResponse {
        var body: [String: Any] = ["platform": "IOS"]
        if let pushToken { body["pushToken"] = pushToken }
        if let voipToken { body["voipToken"] = voipToken }
        return try await post("/me/devices", body: body)
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
    func sendMessage(conversationId: String, body: String?, attachments: [AttachmentDraft]) async throws -> Message {
        var payload: [String: Any] = [:]
        if let body, !body.isEmpty { payload["body"] = body }
        payload["attachments"] = attachments.map { a -> [String: Any] in
            var d: [String: Any] = ["key": a.key, "kind": a.kind, "contentType": a.contentType, "byteSize": a.byteSize]
            if let w = a.width { d["width"] = w }
            if let h = a.height { d["height"] = h }
            if let ms = a.durationMs { d["durationMs"] = ms }
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

    private func request<T: Decodable>(_ path: String, method: String, body: Data?, authed: Bool) async throws -> T {
        // Concatenate so query strings (`?username=…`) are preserved — appendingPathComponent
        // would percent-encode the `?` into the path and 404 the route.
        guard let url = URL(string: Self.baseURL.absoluteString + path) else { throw APIError.noData }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authed, let token = TokenStore.accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (respData, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.noData }
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
}

struct EmptyResponse: Decodable {}
