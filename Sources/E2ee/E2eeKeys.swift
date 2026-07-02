import Foundation
import LibSignalClient

// ── Wire DTOs for the key-distribution endpoints (E2EE.md §6.2) ──────────────

struct OneTimePreKeyDto: Codable {
    let keyId: UInt32
    let publicKey: String
}

struct SignedPreKeyDto: Codable {
    let keyId: UInt32
    let publicKey: String
    let signature: String
}

struct KyberPreKeyDto: Codable {
    let keyId: UInt32
    let publicKey: String
    let signature: String
}

struct PublishKeysRequest: Codable {
    let installId: String
    let platform: String
    let registrationId: Int
    let identityKey: String
    let signedPreKey: SignedPreKeyDto
    let kyberLastResort: KyberPreKeyDto
    let oneTimePreKeys: [OneTimePreKeyDto]
    let kyberPreKeys: [KyberPreKeyDto]
}

struct PublishKeysResponse: Codable { let deviceId: Int }

struct PreKeyCountResponse: Codable {
    let oneTimePreKeys: Int
    let kyberPreKeys: Int
}

struct TopUpPreKeysRequest: Codable {
    let installId: String
    let oneTimePreKeys: [OneTimePreKeyDto]
    let kyberPreKeys: [KyberPreKeyDto]
}

struct RotateSignedPreKeyRequest: Codable {
    let installId: String
    let signedPreKey: SignedPreKeyDto
}

// ── Bundle fetch + device directory + ciphertext send (E2EE.md §6.2–6.3) ─────

struct DeviceBundleDto: Codable {
    let deviceId: UInt32
    let registrationId: UInt32
    let identityKey: String
    let signedPreKey: SignedPreKeyDto
    let preKey: OneTimePreKeyDto?
    let kyberPreKey: KyberPreKeyDto?
}

struct UserKeysResponse: Codable {
    let userId: String
    let devices: [DeviceBundleDto]
}

struct DeviceDirEntry: Codable {
    let userId: String
    let deviceId: UInt32
    let registrationId: UInt32
    let identityKey: String
}

struct DeviceDirectoryResponse: Codable { let devices: [DeviceDirEntry] }

struct CipherEnvelopeDto: Codable {
    let userId: String
    let deviceId: UInt32
    let type: Int
    let ciphertext: String
}

struct CipherSendRequest: Codable {
    var kind: String = "CIPHERTEXT"
    let senderDeviceId: Int
    let envelopes: [CipherEnvelopeDto]
}

// ── Local key state (sealed to disk by E2eeVault) ─────────────────────────────

/// Schema v2: all protocol records (prekeys, signed prekeys, Kyber keys,
/// sessions, peer identities) live in the store snapshot, and the Kyber
/// last-resort key uses the reserved id. v1 state fails Codable decoding
/// (no `store` key) and is regenerated — intended: v1 published a last-resort
/// key whose id collided with one-time kyber id 1, and no sessions exist yet.
private struct E2eeState: Codable {
    var schemaV: Int
    var installId: String
    var deviceId: Int?
    var registrationId: Int
    var identity: Data // serialized IdentityKeyPair
    var currentSignedPreKeyId: UInt32
    var signedPreKeyCreatedAt: UInt64 // epoch ms
    var nextPreKeyId: UInt32
    var nextKyberId: UInt32
    var nextSignedId: UInt32
    var store: E2eeStoreSnapshot
}

/// Reference box so the store's synchronous write-through callback can update
/// the persisted state from inside libsignal operations (the actor's serial
/// execution makes this safe).
private final class E2eeStateBox {
    var state: E2eeState
    init(_ state: E2eeState) { self.state = state }

    func save() { try? E2eeVault.save(state) }
}

/**
 This install's Signal-protocol identity and key material — the iOS mirror of
 Android's `E2eeKeyManager` (schema v2). The actor serializes every protocol
 operation; libsignal session state is read-modify-write.
 */
actor E2eeKeyManager {
    static let shared = E2eeKeyManager()

    private static let schema = 2
    private static let preKeyBatch: UInt32 = 100
    private static let kyberBatch: UInt32 = 50
    private static let topUpThreshold = 20
    private static let signedPreKeyMaxAgeMs: UInt64 = 7 * 24 * 60 * 60 * 1000

    private var box: E2eeStateBox?
    private var cachedStore: KlicSignalStore?

    /// The protocol deviceId assigned by the server, or nil before first publish.
    func localDeviceId() -> Int? { loadBox()?.state.deviceId }

    /// The libsignal store for session operations (actor-isolated). Nil until
    /// keys have been generated, published, and assigned a deviceId.
    func protocolStore() -> KlicSignalStore? {
        guard let box = loadBox(), box.state.deviceId != nil else { return nil }
        return store(for: box)
    }

    /// Bring this install's published bundle up to date. Called on every
    /// successful auth; safe to call repeatedly.
    func ensureReady() async {
        do {
            guard let box = loadBox(), box.state.schemaV == Self.schema else {
                if box != nil { E2eeVault.destroy(); self.box = nil; cachedStore = nil }
                try await generateAndPublish()
                return
            }
            if box.state.deviceId == nil {
                try await publish(box) // an earlier publish never landed
            } else {
                try await maintain(box)
            }
        } catch {
            print("E2ee key upkeep failed (will retry on next auth): \(error)")
        }
    }

    // MARK: - State plumbing

    private func loadBox() -> E2eeStateBox? {
        if let box { return box }
        guard let state = E2eeVault.load(E2eeState.self) else { return nil }
        let box = E2eeStateBox(state)
        self.box = box
        return box
    }

    private func store(for box: E2eeStateBox) -> KlicSignalStore? {
        if let cachedStore { return cachedStore }
        guard let identity = try? IdentityKeyPair(bytes: box.state.identity) else { return nil }
        let store = KlicSignalStore(
            identity: identity,
            registrationId: UInt32(box.state.registrationId),
            snapshot: box.state.store
        ) { [box] snapshot in
            box.state.store = snapshot
            box.save()
        }
        cachedStore = store
        return store
    }

    // MARK: - Generation + publish

    private func generateAndPublish() async throws {
        let identity = IdentityKeyPair.generate()
        let now = UInt64(Date().timeIntervalSince1970 * 1000)

        let signedRecord = try Self.makeSignedPreKey(identity: identity, id: 1, now: now)
        let kyberLastResort = try Self.makeKyberPreKey(identity: identity, id: E2eeIds.kyberLastResort, now: now)
        let preKeys = try (1...Self.preKeyBatch).map {
            try PreKeyRecord(id: $0, privateKey: PrivateKey.generate())
        }
        let kyberPreKeys = try (1...Self.kyberBatch).map {
            try Self.makeKyberPreKey(identity: identity, id: $0, now: now)
        }

        var snapshot = E2eeStoreSnapshot()
        for record in preKeys { snapshot.preKeys[String(record.id)] = record.serialize() }
        snapshot.signedPreKeys["1"] = signedRecord.serialize()
        for record in kyberPreKeys + [kyberLastResort] {
            snapshot.kyberPreKeys[String(record.id)] = record.serialize()
        }

        var state = E2eeState(
            schemaV: Self.schema,
            installId: UUID().uuidString,
            deviceId: nil,
            registrationId: Int.random(in: 1...16380),
            identity: identity.serialize(),
            currentSignedPreKeyId: 1,
            signedPreKeyCreatedAt: now,
            nextPreKeyId: Self.preKeyBatch + 1,
            nextKyberId: Self.kyberBatch + 1,
            nextSignedId: 2,
            store: snapshot)
        // Persist before the network call: a failed publish retries with the
        // same keys next auth instead of minting a fresh identity.
        try E2eeVault.save(state)
        let box = E2eeStateBox(state)
        self.box = box
        cachedStore = nil
        try await publish(box)
    }

    private func publish(_ box: E2eeStateBox) async throws {
        let state = box.state
        let identity = try IdentityKeyPair(bytes: state.identity)
        guard
            let signedData = state.store.signedPreKeys[String(state.currentSignedPreKeyId)],
            let kyberLastResortData = state.store.kyberPreKeys[String(E2eeIds.kyberLastResort)]
        else {
            E2eeVault.destroy()
            self.box = nil
            cachedStore = nil
            try await generateAndPublish()
            return
        }

        let signedRecord = try SignedPreKeyRecord(bytes: signedData)
        let kyberLastResort = try KyberPreKeyRecord(bytes: kyberLastResortData)
        let preKeys = try state.store.preKeys.values.map { try PreKeyRecord(bytes: $0) }
        let kyberPreKeys = try state.store.kyberPreKeys
            .filter { $0.key != String(E2eeIds.kyberLastResort) }
            .values.map { try KyberPreKeyRecord(bytes: $0) }

        let response = try await APIClient.shared.publishKeys(PublishKeysRequest(
            installId: state.installId,
            platform: "IOS",
            registrationId: state.registrationId,
            identityKey: identity.publicKey.serialize().base64EncodedString(),
            signedPreKey: try signedRecord.toDto(),
            kyberLastResort: try kyberLastResort.toDto(),
            oneTimePreKeys: try preKeys.map { try $0.toDto() },
            kyberPreKeys: try kyberPreKeys.map { try $0.toDto() }))

        box.state.deviceId = response.deviceId
        box.save()
        print("E2ee: published key bundle as device \(response.deviceId)")
    }

    // MARK: - Upkeep: top-up + rotation

    private func maintain(_ box: E2eeStateBox) async throws {
        let counts: PreKeyCountResponse
        do {
            counts = try await APIClient.shared.preKeyCount(installId: box.state.installId)
        } catch let APIError.server(_, status) where status == 404 {
            // The server no longer knows this install (e.g. a dev DB reset).
            try await publish(box)
            return
        }

        if counts.oneTimePreKeys < Self.topUpThreshold || counts.kyberPreKeys < Self.topUpThreshold {
            try await topUp(box)
        }

        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        if now > box.state.signedPreKeyCreatedAt,
           now - box.state.signedPreKeyCreatedAt > Self.signedPreKeyMaxAgeMs {
            try await rotateSignedPreKey(box)
        }
    }

    private func topUp(_ box: E2eeStateBox) async throws {
        let identity = try IdentityKeyPair(bytes: box.state.identity)
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let nextPre = box.state.nextPreKeyId
        let nextKyber = box.state.nextKyberId

        let preKeys = try (nextPre..<nextPre + Self.preKeyBatch).map {
            try PreKeyRecord(id: $0, privateKey: PrivateKey.generate())
        }
        let kyberPreKeys = try (nextKyber..<nextKyber + Self.kyberBatch).map {
            try Self.makeKyberPreKey(identity: identity, id: $0, now: now)
        }

        _ = try await APIClient.shared.topUpPreKeys(TopUpPreKeysRequest(
            installId: box.state.installId,
            oneTimePreKeys: try preKeys.map { try $0.toDto() },
            kyberPreKeys: try kyberPreKeys.map { try $0.toDto() }))

        for record in preKeys { box.state.store.preKeys[String(record.id)] = record.serialize() }
        for record in kyberPreKeys { box.state.store.kyberPreKeys[String(record.id)] = record.serialize() }
        box.state.nextPreKeyId = nextPre + Self.preKeyBatch
        box.state.nextKyberId = nextKyber + Self.kyberBatch
        box.save()
        cachedStore = nil // rebuilt from the updated snapshot on next use
        print("E2ee: topped up prekeys (+\(Self.preKeyBatch) EC, +\(Self.kyberBatch) kyber)")
    }

    private func rotateSignedPreKey(_ box: E2eeStateBox) async throws {
        let identity = try IdentityKeyPair(bytes: box.state.identity)
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let record = try Self.makeSignedPreKey(identity: identity, id: box.state.nextSignedId, now: now)

        _ = try await APIClient.shared.rotateSignedPreKey(RotateSignedPreKeyRequest(
            installId: box.state.installId, signedPreKey: try record.toDto()))

        // Keep superseded records: in-flight PreKey messages may still reference them.
        box.state.store.signedPreKeys[String(record.id)] = record.serialize()
        box.state.currentSignedPreKeyId = record.id
        box.state.signedPreKeyCreatedAt = now
        box.state.nextSignedId = record.id + 1
        box.save()
        cachedStore = nil
        print("E2ee: rotated signed prekey to id \(record.id)")
    }

    // MARK: - Record helpers

    private static func makeSignedPreKey(identity: IdentityKeyPair, id: UInt32, now: UInt64) throws -> SignedPreKeyRecord {
        let priv = PrivateKey.generate()
        return try SignedPreKeyRecord(
            id: id, timestamp: now, privateKey: priv,
            signature: identity.privateKey.generateSignature(message: priv.publicKey.serialize()))
    }

    private static func makeKyberPreKey(identity: IdentityKeyPair, id: UInt32, now: UInt64) throws -> KyberPreKeyRecord {
        let pair = KEMKeyPair.generate()
        return try KyberPreKeyRecord(
            id: id, timestamp: now, keyPair: pair,
            signature: identity.privateKey.generateSignature(message: pair.publicKey.serialize()))
    }
}

// MARK: - Record → DTO helpers

private extension PreKeyRecord {
    func toDto() throws -> OneTimePreKeyDto {
        OneTimePreKeyDto(keyId: id, publicKey: try publicKey().serialize().base64EncodedString())
    }
}

private extension SignedPreKeyRecord {
    func toDto() throws -> SignedPreKeyDto {
        SignedPreKeyDto(
            keyId: id,
            publicKey: try publicKey().serialize().base64EncodedString(),
            signature: signature.base64EncodedString())
    }
}

private extension KyberPreKeyRecord {
    func toDto() throws -> KyberPreKeyDto {
        KyberPreKeyDto(
            keyId: id,
            publicKey: try publicKey().serialize().base64EncodedString(),
            signature: signature.base64EncodedString())
    }
}
