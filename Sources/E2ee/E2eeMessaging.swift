import Foundation

/// Feature gate: flips on together with Android at the cutover release (E2EE.md §16).
enum E2eeConfig {
    static let sendEnabled = false
}

/// Locally persisted decrypted content of CIPHERTEXT messages, one sealed file
/// per conversation (AES-GCM via `E2eeVault`, excluded from backups by nature
/// of the vault's this-device-only key). The sender receives no envelope for
/// itself, so this store is the on-device source of truth for sent messages.
actor E2eeMessageStore {
    struct Stored: Codable {
        let senderId: String
        let senderDeviceId: Int
        let content: E2eeContent
        let createdAt: String
    }

    private var cache: [String: [String: Stored]] = [:] // conversationId → messageId → stored

    func save(messageId: String, conversationId: String, senderId: String, senderDeviceId: Int, content: E2eeContent, createdAt: String) {
        var messages = load(conversationId)
        messages[messageId] = Stored(
            senderId: senderId, senderDeviceId: senderDeviceId, content: content, createdAt: createdAt)
        cache[conversationId] = messages
        try? E2eeVault.save(messages, file: Self.file(conversationId))
    }

    func get(conversationId: String, messageId: String) -> E2eeContent? {
        load(conversationId)[messageId]?.content
    }

    private func load(_ conversationId: String) -> [String: Stored] {
        if let cached = cache[conversationId] { return cached }
        let loaded = E2eeVault.load([String: Stored].self, file: Self.file(conversationId)) ?? [:]
        cache[conversationId] = loaded
        return loaded
    }

    private static func file(_ conversationId: String) -> String { "e2ee-msg-\(conversationId).sealed" }
}

/**
 The bridge between the wire and the UI for E2EE messages — the iOS mirror of
 Android's `E2eeMessaging`: materializes CIPHERTEXT payloads into renderable
 `Message`s (store-first, decrypt-once) and encrypts outgoing text for the
 conversation's device directory with one retry on 409 STALE_DEVICES.
 */
actor E2eeMessaging {
    static let shared = E2eeMessaging()

    private let store = E2eeMessageStore()

    // MARK: - Receive

    func materialize(_ message: Message) async -> Message {
        guard message.kind == "CIPHERTEXT", !message.isDeleted else { return message }

        let content: E2eeContent?
        if let stored = await store.get(conversationId: message.conversationId, messageId: message.id) {
            content = stored
        } else {
            content = await decryptAndStore(message)
        }

        switch content {
        case nil:
            let mine = message.senderId == AccessToken.subject(of: TokenStore.accessToken)
            return message.shaped(kind: "TEXT", body: mine
                ? "🔒 Sent from another device"
                : "🔒 Waiting for keys — open Klic on the sending device")
        case let c? where c.type == "text":
            var shaped = message.shaped(kind: "TEXT", body: c.text ?? "")
            if let quote = c.quote {
                shaped.replyTo = ReplyPreview(
                    id: quote.messageId, senderId: "", kind: quote.kind, preview: quote.preview)
            }
            return shaped
        case let c? where c.type == "sticker":
            var shaped = message.shaped(kind: "STICKER", body: "")
            shaped.stickerId = c.stickerId
            return shaped
        default:
            return message.shaped(kind: "TEXT", body: "🔒 Update Klic to view this message")
        }
    }

    func materializeAll(_ messages: [Message]) async -> [Message] {
        var out: [Message] = []
        out.reserveCapacity(messages.count)
        for message in messages { out.append(await materialize(message)) }
        return out
    }

    // MARK: - Send

    /// Encrypt and send a text message; retries once on 409 STALE_DEVICES.
    func sendText(conversationId: String, text: String, quote: E2eeQuote? = nil) async throws -> Message {
        let content = E2eeContent.text(text, quote: quote)
        var directory = try await APIClient.shared.conversationDevices(conversationId: conversationId).devices

        for attempt in 0..<2 {
            let fanOut = try await E2eeKeyManager.shared.encryptForDirectory(content, directory: directory)
            do {
                let sent = try await APIClient.shared.sendCiphertext(
                    conversationId: conversationId,
                    body: CipherSendRequest(senderDeviceId: fanOut.senderDeviceId, envelopes: fanOut.envelopes))
                await store.save(
                    messageId: sent.id, conversationId: conversationId, senderId: sent.senderId,
                    senderDeviceId: fanOut.senderDeviceId, content: content, createdAt: sent.createdAt)
                return await materialize(sent)
            } catch let APIError.server(message, status) where status == 409 && attempt == 0 {
                // The device directory changed under us — refresh and re-encrypt.
                _ = message
                directory = try await APIClient.shared.conversationDevices(conversationId: conversationId).devices
            }
        }
        throw APIError.server(message: "device directory kept changing", status: 409)
    }

    // MARK: - Internals

    private func decryptAndStore(_ message: Message) async -> E2eeContent? {
        guard
            let senderDeviceId = message.senderDeviceId,
            let myDeviceId = await E2eeKeyManager.shared.localDeviceId(),
            let envelope = (message.envelopes ?? []).first(where: { $0.deviceId == UInt32(myDeviceId) }),
            let content = await E2eeKeyManager.shared.decryptEnvelope(
                senderUserId: message.senderId,
                senderDeviceId: UInt32(senderDeviceId),
                type: envelope.type,
                ciphertextB64: envelope.ciphertext)
        else { return nil }
        await store.save(
            messageId: message.id, conversationId: message.conversationId, senderId: message.senderId,
            senderDeviceId: senderDeviceId, content: content, createdAt: message.createdAt)
        return content
    }
}

private extension Message {
    /// `kind` and `body` are lets — rebuild the value around them.
    func shaped(kind newKind: String, body newBody: String) -> Message {
        Message(
            id: id, conversationId: conversationId, senderId: senderId, body: newBody,
            kind: newKind, createdAt: createdAt, attachments: attachments, status: status,
            stickerId: stickerId, stickerUrl: stickerUrl, call: call, replyTo: replyTo,
            reactions: reactions, deletedAt: deletedAt, starred: starred,
            senderDeviceId: senderDeviceId, envelopes: envelopes)
    }
}
