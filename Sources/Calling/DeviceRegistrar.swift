import Foundation

/// Holds the latest APNs + VoIP tokens and registers them with the backend once the
/// user is authenticated. Call `sync()` when a token arrives or after login.
@MainActor
enum DeviceRegistrar {
    static var apnsToken: String?
    static var voipToken: String?

    static func sync() {
        guard TokenStore.accessToken != nil, apnsToken != nil || voipToken != nil else { return }
        Task { _ = try? await APIClient.shared.registerDevice(pushToken: apnsToken, voipToken: voipToken) }
    }
}

extension Data {
    /// Hex string for an APNs/VoIP device token.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
