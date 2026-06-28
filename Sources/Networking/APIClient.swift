import Foundation

enum APIError: Error { case badStatus(Int), decoding, noData }

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

    // MARK: - Core

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await request(path, method: "GET", body: nil, authed: true)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], authed: Bool = true) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await request(path, method: "POST", body: data, authed: authed)
    }

    private func request<T: Decodable>(_ path: String, method: String, body: Data?, authed: Bool) async throws -> T {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent(String(path.dropFirst())))
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authed, let token = TokenStore.accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (respData, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.noData }
        guard (200..<300).contains(http.statusCode) else { throw APIError.badStatus(http.statusCode) }

        if respData.isEmpty, let empty = EmptyResponse() as? T { return empty }
        do { return try JSONDecoder().decode(T.self, from: respData) }
        catch { throw APIError.decoding }
    }
}

struct EmptyResponse: Decodable {}
