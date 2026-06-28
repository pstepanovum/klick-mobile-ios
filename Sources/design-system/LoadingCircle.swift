import SwiftUI

struct LoadingCircle: View {
    var size: CGFloat = 20
    var color: Color = KlicColor.primary

    @State private var isRotating = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(color, style: StrokeStyle(lineWidth: max(2, size * 0.125), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    isRotating = true
                }
            }
    }
}
