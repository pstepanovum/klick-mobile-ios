import Foundation
import LibSignalClient

/// What actually gets encrypted (E2EE.md §7) — field-for-field compatible with
/// the Android `E2eeContent`. Replies, reactions, deletes and stickers travel
/// here, never as server-readable fields. Unknown `type`s render as
/// "update Klic" on old clients.
struct E2eeContent: Codable, Equatable {
    var v: Int = 1
    var type: String // "text" | "reaction" | "sticker" | "delete"
    var text: String?
    var emoji: String?
    var remove: Bool?
    var targetMessageId: String?
    var stickerId: String?
    var quote: E2eeQuote?

    static func text(_ body: String, quote: E2eeQuote? = nil) -> E2eeContent {
        E2eeContent(type: "text", text: body, quote: quote)
    }
}

/// Sender-built preview of the quoted message (the recipient verifies locally).
struct E2eeQuote: Codable, Equatable {
    let messageId: String
    let preview: String
    let kind: String
}

enum E2eeCodec {
    static func encode(_ content: E2eeContent) throws -> Data {
        try JSONEncoder().encode(content)
    }

    static func decode(_ plaintext: Data) -> E2eeContent? {
        try? JSONDecoder().decode(E2eeContent.self, from: plaintext)
    }
}

/// An encrypted content payload addressed to every device in a conversation.
struct EncryptedFanOut {
    let senderDeviceId: Int
    let envelopes: [CipherEnvelopeDto]
}

/**
 Session establishment + envelope encryption/decryption on top of
 `E2eeKeyManager`'s protocol store — the iOS mirror of Android's `E2eeSessions`.
 All operations run inside the key manager's actor.
 */
extension E2eeKeyManager {
    /// Encrypt `content` for every device in `directory` except our own sending
    /// device, establishing missing sessions from prekey bundles. The caller
    /// sends the result and retries once with the fresh directory on 409
    /// STALE_DEVICES.
    func encryptForDirectory(_ content: E2eeContent, directory: [DeviceDirEntry]) async throws -> EncryptedFanOut {
        guard let store = protocolStore(), let myDeviceId = localDeviceId() else {
            throw APIError.server(message: "E2EE keys not ready", status: 0)
        }
        let context = NullContext()
        let plaintext = try E2eeCodec.encode(content)
        let myIdentity = try store.identityKeyPair(context: context)
            .publicKey.serialize().base64EncodedString()

        let targets = directory.filter {
            !($0.deviceId == UInt32(myDeviceId) && $0.identityKey == myIdentity)
        }

        // Establish sessions first — one bundle fetch per user that needs any.
        let missing = try targets.filter {
            !store.containsSession(for: try ProtocolAddress(name: $0.userId, deviceId: $0.deviceId))
        }
        for userId in Set(missing.map(\.userId)) {
            let bundles = try await APIClient.shared.userKeys(userId: userId)
            for target in missing where target.userId == userId {
                guard let bundle = bundles.devices.first(where: { $0.deviceId == target.deviceId }) else {
                    continue // vanished device — the server's coverage check will 409 us
                }
                try processPreKeyBundle(
                    try bundle.toPreKeyBundle(),
                    for: try ProtocolAddress(name: target.userId, deviceId: target.deviceId),
                    sessionStore: store,
                    identityStore: store,
                    context: context)
            }
        }

        var envelopes: [CipherEnvelopeDto] = []
        for target in targets {
            do {
                let address = try ProtocolAddress(name: target.userId, deviceId: target.deviceId)
                let message = try signalEncrypt(
                    message: plaintext,
                    for: address,
                    sessionStore: store,
                    identityStore: store,
                    context: context)
                envelopes.append(CipherEnvelopeDto(
                    userId: target.userId,
                    deviceId: target.deviceId,
                    type: message.messageType == .preKey ? 3 : 2,
                    ciphertext: message.serialize().base64EncodedString()))
            } catch {
                print("E2ee: encrypt to \(target.userId)/\(target.deviceId) failed: \(error)")
            }
        }
        return EncryptedFanOut(senderDeviceId: myDeviceId, envelopes: envelopes)
    }

    /// Decrypt an incoming envelope. Returns nil when undecryptable — the UI
    /// shows a placeholder rather than blocking the chat (E2EE.md §8).
    func decryptEnvelope(senderUserId: String, senderDeviceId: UInt32, type: Int, ciphertextB64: String) async -> E2eeContent? {
        guard let store = protocolStore(),
              let bytes = Data(base64Encoded: ciphertextB64) else { return nil }
        let context = NullContext()
        do {
            let address = try ProtocolAddress(name: senderUserId, deviceId: senderDeviceId)
            let plaintext: Data
            switch type {
            case 3:
                plaintext = try signalDecryptPreKey(
                    message: try PreKeySignalMessage(bytes: bytes),
                    from: address,
                    sessionStore: store,
                    identityStore: store,
                    preKeyStore: store,
                    signedPreKeyStore: store,
                    kyberPreKeyStore: store,
                    context: context)
            case 2:
                plaintext = try signalDecrypt(
                    message: try SignalMessage(bytes: bytes),
                    from: address,
                    sessionStore: store,
                    identityStore: store,
                    context: context)
            default:
                return nil
            }
            return E2eeCodec.decode(plaintext)
        } catch {
            print("E2ee: decrypt from \(senderUserId)/\(senderDeviceId) failed: \(error)")
            return nil
        }
    }
}

private extension DeviceBundleDto {
    func toPreKeyBundle() throws -> PreKeyBundle {
        guard let kyber = kyberPreKey else {
            // Kyber is mandatory in modern bundles — the server always supplies
            // one (last-resort fallback when one-times are drained).
            throw APIError.server(message: "bundle lacks kyber prekey", status: 0)
        }
        let identity = try IdentityKey(bytes: Data(base64Encoded: identityKey) ?? Data())
        let signedPub = try PublicKey(Data(base64Encoded: signedPreKey.publicKey) ?? Data())
        let kyberPub = try KEMPublicKey(Data(base64Encoded: kyber.publicKey) ?? Data())

        if let preKey {
            return try PreKeyBundle(
                registrationId: registrationId,
                deviceId: deviceId,
                prekeyId: preKey.keyId,
                prekey: try PublicKey(Data(base64Encoded: preKey.publicKey) ?? Data()),
                signedPrekeyId: signedPreKey.keyId,
                signedPrekey: signedPub,
                signedPrekeySignature: Data(base64Encoded: signedPreKey.signature) ?? Data(),
                identity: identity,
                kyberPrekeyId: kyber.keyId,
                kyberPrekey: kyberPub,
                kyberPrekeySignature: Data(base64Encoded: kyber.signature) ?? Data())
        }
        return try PreKeyBundle(
            registrationId: registrationId,
            deviceId: deviceId,
            signedPrekeyId: signedPreKey.keyId,
            signedPrekey: signedPub,
            signedPrekeySignature: Data(base64Encoded: signedPreKey.signature) ?? Data(),
            identity: identity,
            kyberPrekeyId: kyber.keyId,
            kyberPrekey: kyberPub,
            kyberPrekeySignature: Data(base64Encoded: kyber.signature) ?? Data())
    }
}
