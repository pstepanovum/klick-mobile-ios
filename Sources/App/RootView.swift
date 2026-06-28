import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var callKit = CallKitManager.shared

    var body: some View {
        Group {
            if session.isAuthenticated {
                TabView {
                    ConversationsView()
                        .tabItem { Label("Chats", systemImage: KlicIcon.message.symbol) }
                    FriendsView()
                        .tabItem { Label("Friends", systemImage: KlicIcon.user.symbol) }
                }
            } else {
                AuthView()
            }
        }
        // The in-call screen is presented whenever CallKit has an active call
        // (outgoing, or an incoming call the user answered from the system UI).
        .fullScreenCover(item: $callKit.activeCall) { call in
            CallView(call: call)
        }
    }
}
