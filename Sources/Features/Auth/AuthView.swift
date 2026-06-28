import SwiftUI
import Inject

struct AuthView: View {
    @ObserveInjection var inject
    @EnvironmentObject var session: AppSession

    @State private var isRegistering = false
    @State private var username = ""
    @State private var password = ""
    @State private var displayName = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("KlicLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 88)

            Text(isRegistering ? "Create your account" : "Welcome back")
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textMuted)
                .padding(.top, 10)

            VStack(spacing: 12) {
                KlicTextField(placeholder: "Username", text: $username)
                if isRegistering {
                    KlicTextField(placeholder: "Display name", text: $displayName)
                }
                KlicTextField(placeholder: "Password", text: $password, isSecure: true)

                if isRegistering && !password.isEmpty {
                    strengthBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.top, 28)
            .animation(.easeInOut(duration: 0.2), value: isRegistering)
            .animation(.easeInOut(duration: 0.2), value: password.isEmpty)

            PillButton(title: isRegistering ? "Sign up" : "Log in") {
                Task {
                    if isRegistering {
                        await session.register(username: username, password: password, displayName: displayName)
                    } else {
                        await session.login(username: username, password: password)
                    }
                }
            }
            .padding(.top, 20)

            Button(isRegistering ? "I already have an account" : "Create an account") {
                withAnimation(.easeInOut(duration: 0.2)) { isRegistering.toggle() }
            }
            .font(KlicFont.medium(14))
            .foregroundStyle(KlicColor.textMuted)
            .padding(.top, 14)

            if let error = session.errorMessage {
                Text(error)
                    .font(KlicFont.caption())
                    .foregroundStyle(KlicColor.danger)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KlicColor.background.ignoresSafeArea())
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .enableInjection()
    }

    // MARK: Password strength

    private var strength: (bars: Int, label: String, color: Color) {
        guard !password.isEmpty else { return (0, "", .clear) }
        let hasUpper   = password.range(of: "[A-Z]", options: .regularExpression) != nil
        let hasDigit   = password.range(of: "[0-9]", options: .regularExpression) != nil
        let hasSpecial = password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil
        if password.count < 8             { return (1, "Weak",   .red) }
        if !hasUpper && !hasDigit         { return (2, "Fair",   .orange) }
        if hasUpper && hasDigit && hasSpecial { return (4, "Strong", Color(red: 0.18, green: 0.8, blue: 0.44)) }
        return (3, "Good", Color(red: 0.55, green: 0.76, blue: 0.0))
    }

    @ViewBuilder
    private var strengthBar: some View {
        let (bars, label, color) = strength
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i < bars ? color : KlicColor.surfaceRaised)
                    .frame(height: 4)
                    .animation(.easeInOut(duration: 0.25), value: bars)
            }
            Text(label)
                .font(KlicFont.caption(12))
                .foregroundStyle(color)
                .frame(width: 44, alignment: .trailing)
                .animation(.easeInOut(duration: 0.25), value: label)
        }
        .padding(.horizontal, 4)
    }
}
