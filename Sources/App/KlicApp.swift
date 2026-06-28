import SwiftUI

@main
struct KlicApp: App {
    @StateObject private var session = AppSession()

    init() {
        // Force the dark, brand-themed UI everywhere.
        UINavigationBar.appearance().tintColor = UIColor(KlicColor.primary)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
                .tint(KlicColor.primary)
                .onAppear { session.bootstrap() }
        }
    }
}
