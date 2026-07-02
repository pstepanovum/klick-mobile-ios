import Foundation

/// App-wide auth/session state.
@MainActor
final class AppSession: ObservableObject {
    @Published var currentUser: User?
    @Published var errorMessage: String?

    private static let userKey = "klic.currentUser"

    var isAuthenticated: Bool { currentUser != nil }

    init() {
        // Optimistic restore: if the Keychain holds a refresh token and we cached the
        // user, show the signed-in UI immediately — no network round-trip, no flash of
        // the welcome screen. bootstrap() confirms (and renews) the session in the
        // background, and only an explicit server rejection signs the user back out.
        if TokenStore.hasSession { currentUser = Self.loadUser() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSessionExpired),
            name: .klicSessionExpired, object: nil)
    }

    /// Called once on launch. Renews the access token only if it's actually expired,
    /// then brings realtime + device registration online. Crucially it never clears
    /// the session on a transient failure — that's what kept logging users out.
    func bootstrap() {
        guard TokenStore.hasSession else { return }
        Task {
            // Refresh up front only when the access token is missing/expired — no
            // gratuitous rotation (and no race) on every relaunch.
            if AccessToken.isExpired(TokenStore.accessToken) {
                await APIClient.shared.refreshAccessToken()
            }
            // A genuine 401 during refresh already signed us out via the notification.
            guard TokenStore.hasSession else { return }
            if currentUser == nil { currentUser = Self.loadUser() }
            SocketService.shared.connect()
            DeviceRegistrar.sync()
            // E2EE: publish/refresh this install's key bundle (generates keys on first run).
            Task { await E2eeKeyManager.shared.ensureReady() }
        }
    }

    func login(username: String, password: String) async {
        await authenticate { try await APIClient.shared.login(username: username, password: password) }
    }

    func register(username: String, password: String, displayName: String) async {
        await authenticate {
            try await APIClient.shared.register(username: username, password: password, displayName: displayName)
        }
    }

    func logout() {
        TokenStore.clear()
        Self.clearUser()
        SocketService.shared.disconnect()
        currentUser = nil
    }

    /// Reflect a profile change (display name, avatar, privacy) into the cached session.
    func updateCurrentUser(_ user: User) {
        currentUser = user
        Self.saveUser(user)
    }

    private func authenticate(_ op: () async throws -> AuthResponse) async {
        do {
            let res = try await op()
            TokenStore.save(access: res.accessToken, refresh: res.refreshToken)
            Self.saveUser(res.user)
            currentUser = res.user
            SocketService.shared.connect()
            DeviceRegistrar.sync()
            Task { await E2eeKeyManager.shared.ensureReady() }
            errorMessage = nil
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }
    }

    /// The server rejected our refresh token — a real sign-out. (Transient network
    /// errors never reach here; they leave the session intact.)
    @objc private func handleSessionExpired() {
        Self.clearUser()
        SocketService.shared.disconnect()
        currentUser = nil
    }

    // MARK: - Cached user (non-secret display data; tokens live in the Keychain)

    private static func saveUser(_ user: User) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        UserDefaults.standard.set(data, forKey: userKey)
    }

    private static func loadUser() -> User? {
        guard let data = UserDefaults.standard.data(forKey: userKey) else { return nil }
        return try? JSONDecoder().decode(User.self, from: data)
    }

    private static func clearUser() {
        UserDefaults.standard.removeObject(forKey: userKey)
    }
}
