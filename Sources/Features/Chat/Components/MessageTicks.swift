import SwiftUI

/// The shared "klic check" mark, drawn from the brand SVG path (viewBox 0 0 268 190)
/// and scaled to whatever frame it's given.
struct KlicCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 268
        let sy = rect.height / 190

        func pt(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var p = Path()
        p.move(to: pt(261.017, 40.3593))
        p.addCurve(to: pt(261.017, 6.92456),
                   control1: pt(270.25, 31.1266), control2: pt(270.25, 16.1573))
        p.addCurve(to: pt(227.583, 6.92456),
                   control1: pt(251.785, -2.30819), control2: pt(236.815, -2.30819))
        p.addLine(to: pt(102.448, 132.059))
        p.addLine(to: pt(40.3593, 69.9697))
        p.addCurve(to: pt(6.92456, 69.9697),
                   control1: pt(31.1266, 60.737), control2: pt(16.1573, 60.737))
        p.addCurve(to: pt(6.92456, 103.404),
                   control1: pt(-2.30819, 79.2025), control2: pt(-2.30819, 94.1717))
        p.addLine(to: pt(85.731, 182.211))
        p.addCurve(to: pt(119.166, 182.211),
                   control1: pt(94.9638, 191.444), control2: pt(109.933, 191.444))
        p.addLine(to: pt(261.017, 40.3593))
        p.closeSubpath()
        return p
    }
}

/// Delivery status indicator — single check (sent), double (delivered), double in the
/// read-accent tint (read). Double = two of the same klic-check glyph overlapped.
struct MessageTicks: View {
    let status: String
    var onPrimary: Bool = false

    private static let glyphSize = CGSize(width: 9.2, height: 6.5)
    private static let overlapOffset: CGFloat = 4.2

    var body: some View {
        let isRead = status == "read"
        let double = status != "sent"
        let color: Color = isRead
            ? KlicColor.read
            : (onPrimary ? KlicColor.onPrimary.opacity(0.65) : KlicColor.textMuted)
        ZStack(alignment: .leading) {
            KlicCheckShape()
                .fill(color)
                .frame(width: Self.glyphSize.width, height: Self.glyphSize.height)
            if double {
                KlicCheckShape()
                    .fill(color)
                    .frame(width: Self.glyphSize.width, height: Self.glyphSize.height)
                    .offset(x: Self.overlapOffset)
            }
        }
        .frame(width: Self.glyphSize.width + (double ? Self.overlapOffset : 0),
               height: Self.glyphSize.height,
               alignment: .leading)
    }
}
