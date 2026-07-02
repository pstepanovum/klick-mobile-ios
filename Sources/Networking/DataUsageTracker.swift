import Foundation
import Network

/// Local, persisted network-usage accounting for the Data & Storage page (CALLS.md §8.3).
///
/// Every byte the app's own networking moves is attributed to a media type, a direction
/// (sent/received) and the network it traveled on (Wi-Fi vs Cellular, from NWPathMonitor's
/// `isExpensive`/cellular flag at the moment of the transfer). Counters persist in
/// UserDefaults and only reset via "Reset Statistics".
///
/// Instrumented paths: APIClient requests (signaling/JSON = "other", `/calls*` = "calls"),
/// attachment uploads (by content type), attachment/file downloads (by attachment kind),
/// and the remote-image pipeline (photos). LiveKit media bytes are NOT counted — calls
/// show as "Calls (signaling)".
final class DataUsageTracker: @unchecked Sendable {
    static let shared = DataUsageTracker()

    enum MediaType: String, CaseIterable {
        case photos, videos, audio, documents, calls, other

        var label: String {
            switch self {
            case .photos: return "Photos"
            case .videos: return "Videos"
            case .audio: return "Audio"
            case .documents: return "Documents"
            case .calls: return "Calls (signaling)"
            case .other: return "Other"
            }
        }
    }

    enum Direction: String, CaseIterable { case sent, received }
    enum NetworkKind: String, CaseIterable { case wifi, mobile }

    private let queue = DispatchQueue(label: "klic.datausage")
    private let monitor = NWPathMonitor()
    private let defaultsKey = "datausage.counters.v1"

    /// "network.type.direction" → bytes.
    private var counters: [String: Int64]
    private var persistScheduled = false

    /// True while the active path is cellular/expensive — also consulted by the
    /// media auto-download matrix.
    private(set) var isOnCellular = false

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        counters = stored.compactMapValues { ($0 as? NSNumber)?.int64Value }
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.isExpensive || path.usesInterfaceType(.cellular)
            self?.queue.async { self?.isOnCellular = cellular }
        }
        monitor.start(queue: queue)
    }

    /// Attribute one transfer to the current network. Cheap: bumps in-memory counters
    /// and coalesces UserDefaults writes.
    func record(type: MediaType, sent: Int, received: Int) {
        guard sent > 0 || received > 0 else { return }
        queue.async {
            let network: NetworkKind = self.isOnCellular ? .mobile : .wifi
            if sent > 0 { self.counters[Self.key(network, type, .sent), default: 0] += Int64(sent) }
            if received > 0 { self.counters[Self.key(network, type, .received), default: 0] += Int64(received) }
            self.schedulePersist()
        }
    }

    /// Media type for an upload, from its MIME type.
    static func mediaType(forContentType contentType: String) -> MediaType {
        if contentType.hasPrefix("image/") { return .photos }
        if contentType.hasPrefix("video/") { return .videos }
        if contentType.hasPrefix("audio/") { return .audio }
        return .documents
    }

    /// Media type for a download, from an attachment kind ("IMAGE" | "VIDEO" | "VOICE" | "FILE").
    static func mediaType(forAttachmentKind kind: String) -> MediaType {
        switch kind {
        case "IMAGE": return .photos
        case "VIDEO": return .videos
        case "VOICE": return .audio
        default: return .documents
        }
    }

    // MARK: Reading

    struct Snapshot {
        /// "network.type.direction" → bytes.
        let counters: [String: Int64]

        func bytes(network: NetworkKind?, type: MediaType, direction: Direction) -> Int64 {
            let networks = network.map { [$0] } ?? NetworkKind.allCases
            return networks.reduce(0) { $0 + (counters[DataUsageTracker.key($1, type, direction)] ?? 0) }
        }

        func total(network: NetworkKind?, direction: Direction) -> Int64 {
            MediaType.allCases.reduce(0) { $0 + bytes(network: network, type: $1, direction: direction) }
        }
    }

    func snapshot() -> Snapshot {
        queue.sync { Snapshot(counters: counters) }
    }

    func reset() {
        queue.async {
            self.counters = [:]
            UserDefaults.standard.removeObject(forKey: self.defaultsKey)
        }
    }

    // MARK: Internals

    private static func key(_ network: NetworkKind, _ type: MediaType, _ direction: Direction) -> String {
        "\(network.rawValue).\(type.rawValue).\(direction.rawValue)"
    }

    private func schedulePersist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        queue.asyncAfter(deadline: .now() + 2) {
            self.persistScheduled = false
            UserDefaults.standard.set(
                self.counters.mapValues { NSNumber(value: $0) },
                forKey: self.defaultsKey
            )
        }
    }
}
