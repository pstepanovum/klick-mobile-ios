import SwiftUI
import Lottie
import Inject

struct WelcomeView: View {
    @ObserveInjection var inject
    @Environment(\.colorScheme) private var colorScheme
    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if colorScheme == .dark {
                    LottieView(animation: .named("12"))
                        .playing(loopMode: .loop)
                        .colorInvert()
                } else {
                    LottieView(animation: .named("12"))
                        .playing(loopMode: .loop)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .padding(.top, 60)

            Image("KlicLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 88)
                .padding(.top, 28)

            VStack(spacing: 10) {
                Text("Talk. Chat. Connect.")
                    .font(KlicFont.medium(20))
                    .foregroundStyle(KlicColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Crystal-clear calls and instant messages,\nall in one place.")
                    .font(KlicFont.body())
                    .foregroundStyle(KlicColor.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.top, 20)
            .padding(.horizontal, 32)

            Spacer()

            PillButton(title: "Get Started", action: onGetStarted)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)

            Text("Free forever · No ads · Private by design")
                .font(KlicFont.caption(12))
                .foregroundStyle(KlicColor.textMuted)
                .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KlicColor.background.ignoresSafeArea())
        .enableInjection()
    }
}
