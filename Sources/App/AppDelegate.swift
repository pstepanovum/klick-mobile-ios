import UIKit
import PushKit
import UserNotifications

/// Handles push registration: APNs (message alerts) and PushKit VoIP (incoming calls →
/// reported to CallKit immediately so the phone rings even when the app is killed).
final class AppDelegate: NSObject, UIApplicationDelegate {
    private var voipRegistry: PKPushRegistry?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if DEBUG
        Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/iOSInjection.bundle")?.load()
        #endif
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        DispatchQueue.main.async { application.registerForRemoteNotifications() }

        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry
        return true
    }

    // APNs (alert) token
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { @MainActor in
            DeviceRegistrar.apnsToken = token.hexString
            DeviceRegistrar.sync()
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error)")
    }
}

// MARK: - PushKit (VoIP) → CallKit

extension AppDelegate: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        Task { @MainActor in
            DeviceRegistrar.voipToken = pushCredentials.token.hexString
            DeviceRegistrar.sync()
        }
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else { completion(); return }
        let d = payload.dictionaryPayload
        let invite = SocketService.CallInvite(
            id: d["callId"] as? String ?? "",
            conversationId: d["conversationId"] as? String ?? "",
            roomName: d["roomName"] as? String ?? "",
            livekitUrl: d["livekitUrl"] as? String ?? "",
            kind: d["kind"] as? String ?? "AUDIO",
            fromDisplayName: d["fromName"] as? String ?? "Incoming call"
        )
        // iOS requires reporting the call synchronously here (the registry runs on .main),
        // otherwise the app can be terminated and future VoIP pushes blocked.
        MainActor.assumeIsolated {
            CallKitManager.shared.reportIncoming(invite)
        }
        completion()
    }
}

// MARK: - Foreground message banners

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
