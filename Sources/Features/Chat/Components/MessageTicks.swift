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

/// The "check and a half" double-check glyph: ONE shape built from BOTH paths of the
/// brand 376x192 SVG (a full check plus a trailing stroke), per CALLS.md §8.1 — never
/// two single checks overlapped.
struct KlicDoubleCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 376
        let sy = rect.height / 192

        func pt(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var p = Path()
        // Path 1 — the full check.
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

        // Path 2 — the trailing half stroke.
        p.move(to: pt(369.076, 6.92456))
        p.addCurve(to: pt(335.641, 6.92456),
                   control1: pt(359.843, -2.30819), control2: pt(344.874, -2.30819))
        p.addLine(to: pt(191.878, 150.688))
        p.addCurve(to: pt(191.878, 184.123),
                   control1: pt(182.645, 159.921), control2: pt(182.645, 174.89))
        p.addCurve(to: pt(225.313, 184.123),
                   control1: pt(201.111, 193.356), control2: pt(216.08, 193.356))
        p.addLine(to: pt(369.076, 40.3593))
        p.addCurve(to: pt(369.076, 6.92456),
                   control1: pt(378.308, 31.1266), control2: pt(378.308, 16.1573))
        p.closeSubpath()
        return p
    }
}

/// Delivery status indicator — single check (sent), combined double glyph (delivered),
/// combined double glyph in the read-accent tint (read).
struct MessageTicks: View {
    let status: String
    var onPrimary: Bool = false

    private static let singleSize = CGSize(width: 9.2, height: 6.5)
    // 376x192 aspect at the same glyph height as the single check.
    private static let doubleSize = CGSize(width: 12.7, height: 6.5)

    var body: some View {
        let isRead = status == "read"
        let double = status != "sent"
        let color: Color = isRead
            ? KlicColor.read
            : (onPrimary ? KlicColor.onPrimary.opacity(0.65) : KlicColor.textMuted)
        Group {
            if double {
                KlicDoubleCheckShape()
                    .fill(color)
                    .frame(width: Self.doubleSize.width, height: Self.doubleSize.height)
            } else {
                KlicCheckShape()
                    .fill(color)
                    .frame(width: Self.singleSize.width, height: Self.singleSize.height)
            }
        }
    }
}
