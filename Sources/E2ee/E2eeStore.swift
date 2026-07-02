import Foundation
import LibSignalClient

/// Everything the Signal protocol store persists, as one Codable value — sealed
/// to disk as a unit by `E2eeVault`. Values are serialized libsignal records;
/// map keys are "userId.deviceId" addresses or integer key ids as strings
/// (matching the Android layout).
struct E2eeStoreSnapshot: Codable {
    var sessions: [String: Data] = [:]
    var identities: [String: Data] = [:]
    var preKeys: [String: Data] = [:]
    var signedPreKeys: [String: Data] = [:]
    var kyberPreKeys: [String: Data] = [:]
    /// "kyberId:baseKeyB64" pairs already used against the last-resort key.
    var usedKyberBaseKeys: Set<String> = []
    var senderKeys: [String: Data] = [:]
}

/// Reserved protocol key ids.
enum E2eeIds {
    /// The Kyber last-resort prekey id — reserved so it can never collide with
    /// one-time Kyber ids (which count up from 1); records are looked up by id.
    static let kyberLastResort: UInt32 = 0xFFFFFF
}

/// libsignal store backed by in-memory maps with write-through persistence:
/// every mutation hands a fresh snapshot to `persist`. Not thread-safe by
/// itself — all protocol operations run inside the `E2eeKeyManager` actor.
///
/// Identity trust is trust-on-first-use; a changed key is recorded (for the
/// Phase 6 safety-number UI) but `isTrustedIdentity` returns false until the
/// app explicitly accepts the new identity.
final class KlicSignalStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore, SessionStore, SenderKeyStore {
    private let identity: IdentityKeyPair
    private let registrationId: UInt32
    private var snap: E2eeStoreSnapshot
    private let persist: (E2eeStoreSnapshot) -> Void

    init(
        identity: IdentityKeyPair,
        registrationId: UInt32,
        snapshot: E2eeStoreSnapshot,
        persist: @escaping (E2eeStoreSnapshot) -> Void
    ) {
        self.identity = identity
        self.registrationId = registrationId
        self.snap = snapshot
        self.persist = persist
    }

    func snapshot() -> E2eeStoreSnapshot { snap }

    private func save() { persist(snap) }

    private func key(_ address: ProtocolAddress) -> String { "\(address.name).\(address.deviceId)" }

    // MARK: - IdentityKeyStore

    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair { identity }

    func localRegistrationId(context: StoreContext) throws -> UInt32 { registrationId }

    func saveIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityChange {
        let k = key(address)
        let previous = snap.identities[k]
        let encoded = identity.serialize()
        snap.identities[k] = encoded
        save()
        return (previous == nil || previous == encoded) ? .newOrUnchanged : .replacedExisting
    }

    func isTrustedIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        direction: Direction,
        context: StoreContext
    ) throws -> Bool {
        guard let recorded = snap.identities[key(address)] else { return true } // first contact
        return recorded == identity.serialize()
    }

    func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        try snap.identities[key(address)].map { try IdentityKey(bytes: $0) }
    }

    // MARK: - SessionStore

    func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        try snap.sessions[key(address)].map { try SessionRecord(bytes: $0) }
    }

    func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        try addresses.map { address in
            guard let record = try loadSession(for: address, context: context) else {
                throw SignalError.sessionNotFound("\(address)")
            }
            return record
        }
    }

    func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        snap.sessions[key(address)] = record.serialize()
        save()
    }

    /// Whether a live session exists for the address (used before deciding to fetch a bundle).
    func containsSession(for address: ProtocolAddress) -> Bool {
        snap.sessions[key(address)] != nil
    }

    // MARK: - PreKeyStore

    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        guard let data = snap.preKeys[String(id)] else {
            throw SignalError.invalidKeyIdentifier("no prekey \(id)")
        }
        return try PreKeyRecord(bytes: data)
    }

    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        snap.preKeys[String(id)] = record.serialize()
        save()
    }

    func removePreKey(id: UInt32, context: StoreContext) throws {
        snap.preKeys.removeValue(forKey: String(id))
        save()
    }

    // MARK: - SignedPreKeyStore

    func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        guard let data = snap.signedPreKeys[String(id)] else {
            throw SignalError.invalidKeyIdentifier("no signed prekey \(id)")
        }
        return try SignedPreKeyRecord(bytes: data)
    }

    func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        snap.signedPreKeys[String(id)] = record.serialize()
        save()
    }

    // MARK: - KyberPreKeyStore

    func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        guard let data = snap.kyberPreKeys[String(id)] else {
            throw SignalError.invalidKeyIdentifier("no kyber prekey \(id)")
        }
        return try KyberPreKeyRecord(bytes: data)
    }

    func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        snap.kyberPreKeys[String(id)] = record.serialize()
        save()
    }

    func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey, context: StoreContext) throws {
        if id == E2eeIds.kyberLastResort {
            // Reusable across sessions, but never with the same base key twice —
            // that would be a replayed handshake.
            let use = "\(id):\(baseKey.serialize().base64EncodedString())"
            if snap.usedKyberBaseKeys.contains(use) {
                throw SignalError.invalidMessage("reused kyber base key")
            }
            snap.usedKyberBaseKeys.insert(use)
        } else {
            // One-time kyber prekeys are exactly that.
            snap.kyberPreKeys.removeValue(forKey: String(id))
        }
        save()
    }

    // MARK: - SenderKeyStore (groups — Phase 4)

    func storeSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        record: SenderKeyRecord,
        context: StoreContext
    ) throws {
        snap.senderKeys["\(key(sender))/\(distributionId.uuidString)"] = record.serialize()
        save()
    }

    func loadSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        context: StoreContext
    ) throws -> SenderKeyRecord? {
        try snap.senderKeys["\(key(sender))/\(distributionId.uuidString)"].map { try SenderKeyRecord(bytes: $0) }
    }
}
