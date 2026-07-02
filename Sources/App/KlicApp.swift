import SwiftUI
import UserNotifications
import Intents

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
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        // Clear the app-icon badge + delivered banners when the user is back in.
                        UNUserNotificationCenter.current().setBadgeCount(0)
                        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                        if CallKitManager.shared.activeCall == nil {
                            CallActivityController.end()
                        }
                    }
                }
                // Siri / CarPlay / Phone-app Recents call-back → resolve the contact and dial.
                // The legacy audio/video intents cover older routing (still sent by some paths).
                .onContinueUserActivity(NSStringFromClass(INStartCallIntent.self)) { activity in
                    CallIntents.startCall(from: activity)
                }
                .onContinueUserActivity("INStartAudioCallIntent") { activity in
                    CallIntents.startCall(from: activity)
                }
                .onContinueUserActivity("INStartVideoCallIntent") { activity in
                    CallIntents.startCall(from: activity)
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
