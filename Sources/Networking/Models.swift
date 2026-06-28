import Foundation

struct User: Codable, Identifiable, Hashable {
    let id: String
    let username: String
    let displayName: String
    var avatarUrl: String?
    var showLastSeen: Bool?      // present on /me + auth responses
}

/// A friend's profile (GET /users/:id). `lastSeenAt`/`online` are nil when hidden by privacy.
struct UserProfile: Codable, Identifiable, Hashable {
    let id: String
    let username: String
    let displayName: String
    var avatarUrl: String?
    var lastSeenAt: String?
    var online: Bool?
}

struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let user: User
}

struct Conversation: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let members: [Member]
    let lastMessage: Message?

    struct Member: Codable, Hashable {
        let id: String; let username: String; let displayName: String
        var avatarUrl: String?
    }
}

struct Attachment: Codable, Identifiable, Hashable {
    let id: String
    let kind: String            // "IMAGE" | "VOICE" | "VIDEO" | "FILE"
    let url: String             // presigned download URL — expires ~1h; refresh via /attachments/:id/url
    let contentType: String
    let byteSize: Int
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var waveform: String?       // base64-encoded 5-bit packed waveform (VOICE only)
    var fileName: String?

    var isImage: Bool { kind == "IMAGE" }
    var isVoice: Bool { kind == "VOICE" }
    var isVideo: Bool { kind == "VIDEO" }
    var isFile:  Bool { kind == "FILE" }
}

struct Message: Codable, Identifiable, Hashable {
    let id: String
    let conversationId: String
    let senderId: String
    let body: String
    let kind: String
    let createdAt: String
    var attachments: [Attachment] = []
    var status: String?          // "sent" | "delivered" | "read" — own messages only

    enum CodingKeys: String, CodingKey {
        case id, conversationId, senderId, body, kind, createdAt, attachments, status
    }

    // Tolerant decode (body/kind may be empty; attachments absent on older payloads).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        senderId = try c.decode(String.self, forKey: .senderId)
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "TEXT"
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        attachments = (try? c.decode([Attachment].self, forKey: .attachments)) ?? []
        status = try? c.decode(String.self, forKey: .status)
    }

    // Convenience init so building a Message locally stays ergonomic.
    init(id: String, conversationId: String, senderId: String, body: String,
         kind: String, createdAt: String, attachments: [Attachment] = [], status: String? = nil) {
        self.id = id; self.conversationId = conversationId; self.senderId = senderId
        self.body = body; self.kind = kind; self.createdAt = createdAt
        self.attachments = attachments; self.status = status
    }
}

struct FriendRequest: Codable, Identifiable {
    let requestId: String
    let from: From
    var id: String { requestId }

    struct From: Codable { let id: String; let username: String; let displayName: String }
}

struct CallSession: Codable, Identifiable {
    let callId: String
    let roomName: String
    let livekitUrl: String
    let token: String
    var kind: String?
    var id: String { callId }
}

// MARK: - Uploads

/// Server response from POST /uploads — a presigned PUT URL the client uploads to.
struct UploadTicket: Decodable {
    let key: String
    let uploadUrl: String
    let expiresAt: String
    let maxBytes: Int
}

/// One attachment to reference when sending a message (after its bytes are uploaded).
struct AttachmentDraft {
    let key: String
    let kind: String            // "IMAGE" | "VOICE" | "VIDEO" | "FILE"
    let contentType: String
    let byteSize: Int
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var waveform: Data?         // 5-bit packed waveform bytes to send as base64 (VOICE only)
    var fileName: String?
}
