import Foundation

struct User: Codable, Identifiable, Hashable {
    let id: String
    let username: String
    let displayName: String
    var avatarUrl: String?
}

struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let user: User
}

struct Conversation: Codable, Identifiable {
    let id: String
    let type: String
    let members: [Member]
    let lastMessage: Message?

    struct Member: Codable, Hashable { let id: String; let username: String; let displayName: String }
}

struct Message: Codable, Identifiable, Hashable {
    let id: String
    let conversationId: String
    let senderId: String
    let body: String
    let kind: String
    let createdAt: String
}

struct CallSession: Codable {
    let callId: String
    let roomName: String
    let livekitUrl: String
    let token: String
    var kind: String?
}
