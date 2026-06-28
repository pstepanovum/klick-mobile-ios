import ActivityKit
import Foundation

/// Shared between the app (which starts/updates/ends the activity) and the widget
/// extension (which renders it in the Dynamic Island and on the Lock Screen).
struct CallActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String       // "Calling…" / "Connected"
        var muted: Bool
        var isVideo: Bool
    }

    var peerName: String
    var startedAt: Date
}
