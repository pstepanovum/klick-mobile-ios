import ActivityKit
import SwiftUI
import WidgetKit

private let brandRed = Color(red: 0xED / 255, green: 0x12 / 255, blue: 0x2B / 255)
private let surface = Color(red: 0x14 / 255, green: 0x15 / 255, blue: 0x1F / 255)

/// Renders the ongoing-call Live Activity in the Dynamic Island and on the Lock Screen.
struct CallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            // Lock Screen / banner
            HStack(spacing: 12) {
                Image(systemName: context.state.isVideo ? "video.fill" : "phone.fill")
                    .foregroundStyle(brandRed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.peerName).font(.headline).foregroundStyle(.white)
                    Text(context.state.status).font(.caption).foregroundStyle(.gray)
                }
                Spacer()
                Text(context.attributes.startedAt, style: .timer)
                    .monospacedDigit().font(.headline).foregroundStyle(.white).frame(maxWidth: 64)
            }
            .padding()
            .activityBackgroundTint(surface)
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.peerName, systemImage: context.state.isVideo ? "video.fill" : "phone.fill")
                        .foregroundStyle(brandRed)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .monospacedDigit().frame(maxWidth: 56).foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.muted ? "Microphone off" : context.state.status)
                        .font(.caption).foregroundStyle(.gray)
                }
            } compactLeading: {
                Image(systemName: context.state.isVideo ? "video.fill" : "phone.fill")
                    .foregroundStyle(brandRed)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .monospacedDigit().frame(maxWidth: 44).foregroundStyle(.white)
            } minimal: {
                Image(systemName: "phone.fill").foregroundStyle(brandRed)
            }
            .keylineTint(brandRed)
        }
    }
}
