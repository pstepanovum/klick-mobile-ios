import Foundation

/// App-wide auth/session state.
@MainActor
final class AppSession: ObservableObject {
    @Published var currentUser: User?
    @Published var errorMessage: String?

    var isAuthenticated: Bool { currentUser != nil }

    func bootstrap() {
        // A stored token means we can stay signed in; profile fetch happens in M1.
        if TokenStore.accessToken != nil { SocketService.shared.connect() }
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
        SocketService.shared.disconnect()
        currentUser = nil
    }

    private func authenticate(_ op: () async throws -> AuthResponse) async {
        do {
            let res = try await op()
            TokenStore.save(access: res.accessToken, refresh: res.refreshToken)
            currentUser = res.user
            SocketService.shared.connect()
            errorMessage = nil
        } catch {
            errorMessage = "Could not sign in. Check your details and try again."
        }
    }
}
