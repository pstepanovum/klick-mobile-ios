import SwiftUI
import Lottie

struct KlicLottieView: View {
    @Environment(\.colorScheme) private var colorScheme
    let name: String
    var height: CGFloat = 180

    var body: some View {
        Group {
            if colorScheme == .dark {
                LottieView(animation: .named(name))
                    .playing(loopMode: .loop)
                    .colorInvert()
            } else {
                LottieView(animation: .named(name))
                    .playing(loopMode: .loop)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}
