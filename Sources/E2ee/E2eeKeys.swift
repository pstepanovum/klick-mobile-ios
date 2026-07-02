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

// ── Local key state (sealed to disk by E2eeVault) ─────────────────────────────

private struct E2eeState: Codable {
    var installId: String
    var deviceId: Int?
    var registrationId: Int
    var identity: Data // serialized IdentityKeyPair
    var signedPreKeys: [UInt32: Data] // id → serialized record; superseded ones kept
    var currentSignedPreKeyId: UInt32
    var signedPreKeyCreatedAt: UInt64 // epoch ms
    var kyberLastResort: Data
    var preKeys: [UInt32: Data]
    var kyberPreKeys: [UInt32: Data]
    var nextPreKeyId: UInt32
    var nextKyberId: UInt32
    var nextSignedId: UInt32
}

/**
 This install's Signal-protocol identity: identity keypair, signed prekey, and one-time
 EC + Kyber prekeys — the iOS mirror of Android's `E2eeKeyManager`.

 Phase 1 scope: generate, publish, top up, rotate. Sessions (encrypt/decrypt) are Phase 2 —
 private prekey records are retained so Phase 2 can process incoming PreKey messages
 that reference them.
 */
actor E2eeKeyManager {
    static let shared = E2eeKeyManager()

    private static let preKeyBatch: UInt32 = 100
    private static let kyberBatch: UInt32 = 50
    private static let topUpThreshold = 20
    private static let signedPreKeyMaxAgeMs: UInt64 = 7 * 24 * 60 * 60 * 1000

    /// Bring this install's published bundle up to date. Called on every successful
    /// auth; safe to call repeatedly. Failures are logged and retried on the next auth.
    func ensureReady() async {
        do {
            guard var state = E2eeVault.load(E2eeState.self) else {
                try await generateAndPublish()
                return
            }
            if state.deviceId == nil {
                try await publish(&state) // an earlier publish never landed
            } else {
                try await maintain(&state)
            }
        } catch {
            print("E2ee key upkeep failed (will retry on next auth): \(error)")
        }
    }

    // ── Generation + publish ──────────────────────────────────────────────────

    private func generateAndPublish() async throws {
        let identity = IdentityKeyPair.generate()
        let now = UInt64(Date().timeIntervalSince1970 * 1000)

        let signedPriv = PrivateKey.generate()
        let signedRecord = try SignedPreKeyRecord(
            id: 1, timestamp: now, privateKey: signedPriv,
            signature: identity.privateKey.generateSignature(message: signedPriv.publicKey.serialize()))

        let kyberPair = KEMKeyPair.generate()
        let kyberLastResort = try KyberPreKeyRecord(
            id: 1, timestamp: now, keyPair: kyberPair,
            signature: identity.privateKey.generateSignature(message: kyberPair.publicKey.serialize()))

        let preKeys = try (1...Self.preKeyBatch).map {
            try PreKeyRecord(id: $0, privateKey: PrivateKey.generate())
        }
        let kyberPreKeys = try (1...Self.kyberBatch).map { id -> KyberPreKeyRecord in
            let pair = KEMKeyPair.generate()
            return try KyberPreKeyRecord(
                id: id, timestamp: now, keyPair: pair,
                signature: identity.privateKey.generateSignature(message: pair.publicKey.serialize()))
        }

        var state = E2eeState(
            installId: UUID().uuidString,
            deviceId: nil,
            registrationId: Int.random(in: 1...16380),
            identity: identity.serialize(),
            signedPreKeys: [1: signedRecord.serialize()],
            currentSignedPreKeyId: 1,
            signedPreKeyCreatedAt: now,
            kyberLastResort: kyberLastResort.serialize(),
            preKeys: Dictionary(uniqueKeysWithValues: preKeys.map { ($0.id, $0.serialize()) }),
            kyberPreKeys: Dictionary(uniqueKeysWithValues: kyberPreKeys.map { ($0.id, $0.serialize()) }),
            nextPreKeyId: Self.preKeyBatch + 1,
            nextKyberId: Self.kyberBatch + 1,
            nextSignedId: 2)
        // Persist before the network call: if the publish fails we retry with the
        // same keys next auth instead of minting a fresh identity.
        try E2eeVault.save(state)
        try await publish(&state)
    }

    private func publish(_ state: inout E2eeState) async throws {
        let identity = try IdentityKeyPair(bytes: state.identity)
        guard let signedData = state.signedPreKeys[state.currentSignedPreKeyId] else {
            E2eeVault.destroy()
            try await generateAndPublish()
            return
        }
        let signedRecord = try SignedPreKeyRecord(bytes: signedData)
        let kyberLastResort = try KyberPreKeyRecord(bytes: state.kyberLastResort)

        let request = PublishKeysRequest(
            installId: state.installId,
            platform: "IOS",
            registrationId: state.registrationId,
            identityKey: identity.publicKey.serialize().base64EncodedString(),
            signedPreKey: try signedRecord.toDto(),
            kyberLastResort: try kyberLastResort.toDto(),
            oneTimePreKeys: try state.preKeys.values.map { try PreKeyRecord(bytes: $0).toDto() },
            kyberPreKeys: try state.kyberPreKeys.values.map { try KyberPreKeyRecord(bytes: $0).toDto() })

        let response = try await APIClient.shared.publishKeys(request)
        state.deviceId = response.deviceId
        try E2eeVault.save(state)
        print("E2ee: published key bundle as device \(response.deviceId)")
    }

    // ── Upkeep: top-up + rotation ─────────────────────────────────────────────

    private func maintain(_ state: inout E2eeState) async throws {
        let counts: PreKeyCountResponse
        do {
            counts = try await APIClient.shared.preKeyCount(installId: state.installId)
        } catch let APIError.server(_, status) where status == 404 {
            // The server no longer knows this install (e.g. a dev DB reset): publish again.
            try await publish(&state)
            return
        }

        if counts.oneTimePreKeys < Self.topUpThreshold || counts.kyberPreKeys < Self.topUpThreshold {
            try await topUp(&state)
        }

        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        if now > state.signedPreKeyCreatedAt, now - state.signedPreKeyCreatedAt > Self.signedPreKeyMaxAgeMs {
            try await rotateSignedPreKey(&state)
        }
    }

    private func topUp(_ state: inout E2eeState) async throws {
        let identity = try IdentityKeyPair(bytes: state.identity)
        let now = UInt64(Date().timeIntervalSince1970 * 1000)

        let preKeys = try (state.nextPreKeyId..<state.nextPreKeyId + Self.preKeyBatch).map {
            try PreKeyRecord(id: $0, privateKey: PrivateKey.generate())
        }
        let kyberPreKeys = try (state.nextKyberId..<state.nextKyberId + Self.kyberBatch).map { id -> KyberPreKeyRecord in
            let pair = KEMKeyPair.generate()
            return try KyberPreKeyRecord(
                id: id, timestamp: now, keyPair: pair,
                signature: identity.privateKey.generateSignature(message: pair.publicKey.serialize()))
        }

        _ = try await APIClient.shared.topUpPreKeys(TopUpPreKeysRequest(
            installId: state.installId,
            oneTimePreKeys: try preKeys.map { try $0.toDto() },
            kyberPreKeys: try kyberPreKeys.map { try $0.toDto() }))

        for record in preKeys { state.preKeys[record.id] = record.serialize() }
        for record in kyberPreKeys { state.kyberPreKeys[record.id] = record.serialize() }
        state.nextPreKeyId += Self.preKeyBatch
        state.nextKyberId += Self.kyberBatch
        try E2eeVault.save(state)
        print("E2ee: topped up prekeys (+\(Self.preKeyBatch) EC, +\(Self.kyberBatch) kyber)")
    }

    private func rotateSignedPreKey(_ state: inout E2eeState) async throws {
        let identity = try IdentityKeyPair(bytes: state.identity)
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let priv = PrivateKey.generate()
        let record = try SignedPreKeyRecord(
            id: state.nextSignedId, timestamp: now, privateKey: priv,
            signature: identity.privateKey.generateSignature(message: priv.publicKey.serialize()))

        _ = try await APIClient.shared.rotateSignedPreKey(RotateSignedPreKeyRequest(
            installId: state.installId, signedPreKey: try record.toDto()))

        // Keep superseded records: in-flight PreKey messages may still reference them.
        state.signedPreKeys[record.id] = record.serialize()
        state.currentSignedPreKeyId = record.id
        state.signedPreKeyCreatedAt = now
        state.nextSignedId += 1
        try E2eeVault.save(state)
        print("E2ee: rotated signed prekey to id \(record.id)")
    }
}

// ── Record → DTO helpers ──────────────────────────────────────────────────────

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
