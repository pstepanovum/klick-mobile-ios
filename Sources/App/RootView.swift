import SwiftUI
import AVFoundation
import Inject

struct RootView: View {
    @ObserveInjection var inject
    @EnvironmentObject var session: AppSession
    @StateObject private var callKit = CallKitManager.shared
    @State private var didGetStarted = false

    /// Ask for mic + camera the moment the user is signed in — never mid-call. Asking when LiveKit
    /// first touches the devices is jarring and, for a callee, too late: an un-granted mic means the
    /// peer hears silence for the whole call. requestAccess only prompts when status is
    /// .notDetermined, so this is a no-op once the user has answered the prompts.
    private func requestCallPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        AVCaptureDevice.requestAccess(for: .video) { _ in }
    }

    /// The call the fullScreenCover presents: hidden while minimized (the floating overlay
    /// takes over) without touching `activeCall` — dismissing the cover must never tear the
    /// live call down. The setter ignores dismissals for the same reason.
    private var presentedCall: Binding<CallKitManager.ActiveCall?> {
        Binding(
            get: { callKit.callMinimized ? nil : callKit.activeCall },
            set: { _ in }
        )
    }

    var body: some View {
        ZStack {
            Group {
                if session.isAuthenticated {
                    TabView {
                        ConversationsView()
                            .tabItem {
                                Image("ic_line_message_3").renderingMode(.template)
                                Text("Chats")
                            }
                        FriendsView()
                            .tabItem {
                                Image(KlicIcon.user.line).renderingMode(.template)
                                Text("Friends")
                            }
                        CallDialView()
                            .tabItem {
                                Image(KlicIcon.phone.line).renderingMode(.template)
                                Text("Call")
                            }
                        SettingsView()
                            .tabItem {
                                Image(KlicIcon.settings.line).renderingMode(.template)
                                Text("Settings")
                            }
                    }
                    .tint(KlicColor.primary)
                    .onAppear { requestCallPermissions() }
                } else if didGetStarted {
                    AuthView()
                } else {
                    WelcomeView { withAnimation { didGetStarted = true } }
                }
            }

            // Floating in-call overlay while minimized, above all navigation. Disappears on
            // its own when the call ends (activeCall goes nil → callMinimized resets).
            if callKit.callMinimized, let call = callKit.activeCall {
                MinimizedCallOverlay(call: call)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.spring(response: 0.3), value: callKit.callMinimized)
        .fullScreenCover(item: presentedCall) { call in
            CallView(call: call)
        }
        .enableInjection()
    }
}
