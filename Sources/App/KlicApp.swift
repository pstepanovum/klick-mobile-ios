import SwiftUI
import UserNotifications

@main
struct KlicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = AppSession()
    @StateObject private var themeManager = ThemeManager()

    init() {
        configureNavigationBar()
        configureTabBar()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(themeManager)
                .preferredColorScheme(themeManager.colorScheme)
                .tint(KlicColor.primary)
                .onAppear { session.bootstrap() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        // Clear the app-icon badge + delivered banners when the user is back in.
                        UNUserNotificationCenter.current().setBadgeCount(0)
                        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                        if CallKitManager.shared.activeCall == nil {
                            CallActivityController.end()
                        }
                    }
                }
        }
    }

    private func configureNavigationBar() {
        UINavigationBar.appearance().tintColor = UIColor(KlicColor.primary)
    }

    private func configureTabBar() {
        let darkSurface  = UIColor(red: 26/255, green: 26/255, blue: 26/255, alpha: 1)
        let lightSurface = UIColor.white
        let adaptiveBg   = UIColor { $0.userInterfaceStyle == .dark ? darkSurface : lightSurface }

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = adaptiveBg

        UITabBar.appearance().standardAppearance   = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
