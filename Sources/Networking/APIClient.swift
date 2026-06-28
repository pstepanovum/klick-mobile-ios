import Foundation

enum APIError: Error { case badStatus(Int), decoding, noData }

/// Thin async/await REST client for the Klic API. Injects the access token and
/// transparently refreshes it once on a 401.
actor APIClient {
    static let shared = APIClient()

    /// Simulator/dev default. Android uses 10.0.2.2; iOS simulator can reach the host directly.
    static let baseURL = URL(string: "http://localhost:3000/api/v1")!

    private let session = URLSession.shared

    func register(username: String, password: String, displayName: String) async throws -> AuthResponse {
        try await post("/auth/register", body: [
            "username": username, "password": password, "displayName": displayName,
        ], authed: false)
    }

    func login(username: String, password: String) async throws -> AuthResponse {
        try await post("/auth/login", body: ["username": username, "password": password], authed: false)
    }

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
