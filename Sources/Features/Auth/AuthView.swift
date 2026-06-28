import SwiftUI

struct AuthView: View {
    @EnvironmentObject var session: AppSession

    @State private var isRegistering = false
    @State private var username = ""
    @State private var password = ""
    @State private var displayName = ""

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("Klic")
                .font(KlicFont.display(44))
                .foregroundStyle(KlicColor.textPrimary)
            Text(isRegistering ? "Create your account" : "Welcome back")
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textMuted)

            VStack(spacing: 12) {
                KlicTextField(placeholder: "Username", text: $username)
                if isRegistering {
                    KlicTextField(placeholder: "Display name", text: $displayName)
                }
                KlicTextField(placeholder: "Password", text: $password, isSecure: true)
            }
            .padding(.top, 12)

            if isRegistering {
                Text("Username: 3+ characters (a–z, 0–9, . _) · Password: 8+ characters")
                    .font(KlicFont.caption())
                    .foregroundStyle(KlicColor.textMuted)
                    .multilineTextAlignment(.center)
            }

            PillButton(title: isRegistering ? "Sign up" : "Log in") {
                Task {
                    if isRegistering {
                        await session.register(username: username, password: password, displayName: displayName)
                    } else {
                        await session.login(username: username, password: password)
                    }
                }
            }

            Button(isRegistering ? "I already have an account" : "Create an account") {
                isRegistering.toggle()
            }
            .font(KlicFont.medium(14))
            .foregroundStyle(KlicColor.textMuted)

            if let error = session.errorMessage {
                Text(error).font(KlicFont.caption()).foregroundStyle(KlicColor.danger)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KlicColor.background.ignoresSafeArea())
    }
}
