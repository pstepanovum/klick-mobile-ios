import ActivityKit
import Foundation

/// Starts / updates / ends the Dynamic Island Live Activity for an ongoing call.
enum CallActivityController {
    private static var current: Activity<CallActivityAttributes>?

    static func start(peerName: String, isVideo: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let attributes = CallActivityAttributes(peerName: peerName, startedAt: Date())
        let state = CallActivityAttributes.ContentState(status: "Calling…", muted: false, isVideo: isVideo)
        do {
            current = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
        } catch {
            print("LiveActivity start failed: \(error)")
        }
    }

    static func update(status: String, muted: Bool, isVideo: Bool) {
        guard let current else { return }
        let state = CallActivityAttributes.ContentState(status: status, muted: muted, isVideo: isVideo)
        Task { await current.update(.init(state: state, staleDate: nil)) }
    }

    static func end() {
        let stored = current
        let activities = Activity<CallActivityAttributes>.activities
        APIClient.mobileDiagnostic(
            event: "callactivity.end",
            detail: "stored=\(stored != nil) active=\(activities.count)"
        )
        Task {
            if let stored {
                await stored.end(nil, dismissalPolicy: .immediate)
            }
            for activity in activities where activity.id != stored?.id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        self.current = nil
    }
}
