import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var callKit = CallKitManager.shared
    @State private var didGetStarted = false

    var body: some View {
        Group {
            if session.isAuthenticated {
                TabView {
                    ConversationsView()
                        .tabItem { Label("Chats",    image: KlicIcon.message.line) }
                    FriendsView()
                        .tabItem { Label("Friends",  image: KlicIcon.user.line) }
                    CallDialView()
                        .tabItem { Label("Call",     image: KlicIcon.phone.line) }
                    SettingsView()
                        .tabItem { Label("Settings", image: KlicIcon.settings.line) }
                }
            } else if didGetStarted {
                AuthView()
            } else {
                WelcomeView { withAnimation { didGetStarted = true } }
            }
        }
        .fullScreenCover(item: $callKit.activeCall) { call in
            CallView(call: call)
        }
    }
}
