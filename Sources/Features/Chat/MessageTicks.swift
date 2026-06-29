import SwiftUI

/// Delivery status indicator — single tick (sent), double grey (delivered), double green (read).
struct MessageTicks: View {
    let status: String
    var onPrimary: Bool = false

    var body: some View {
        let isRead = status == "read"
        let double = status != "sent"
        let color: Color = isRead
            ? KlicColor.read
            : (onPrimary ? KlicColor.onPrimary.opacity(0.65) : KlicColor.textMuted)
        DoubleCheckmark(double: double, color: color)
    }
}

private struct DoubleCheckmark: View {
    let double: Bool
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width  / 12
            let sy = size.height / 7

            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }

            // Left checkmark (always shown)
            var p1 = Path()
            p1.move(to: pt(8.28033, 1.28033))
            p1.addCurve(to: pt(8.28033, 0.21967),  control1: pt(8.57322, 0.987437),    control2: pt(8.57322, 0.512563))
            p1.addCurve(to: pt(7.21967, 0.21967),  control1: pt(7.98744, -0.0732232),   control2: pt(7.51256, -0.0732232))
            p1.addLine(to: pt(3.25, 4.18934))
            p1.addLine(to: pt(1.28033, 2.21967))
            p1.addCurve(to: pt(0.21967, 2.21967),  control1: pt(0.987437, 1.92678),     control2: pt(0.512563, 1.92678))
            p1.addCurve(to: pt(0.21967, 3.28033),  control1: pt(-0.0732232, 2.51256),   control2: pt(-0.0732232, 2.98744))
            p1.addLine(to: pt(2.71967, 5.78033))
            p1.addCurve(to: pt(3.78033, 5.78033),  control1: pt(3.01256, 6.07322),      control2: pt(3.48744, 6.07322))
            p1.addLine(to: pt(8.28033, 1.28033))
            p1.closeSubpath()
            ctx.fill(p1, with: .color(color))

            if double {
                // Right checkmark
                var p2 = Path()
                p2.move(to: pt(11.7066, 0.21967))
                p2.addCurve(to: pt(10.6459, 0.21967), control1: pt(11.4137, -0.0732232),  control2: pt(10.9388, -0.0732232))
                p2.addLine(to: pt(6.08527, 4.78033))
                p2.addCurve(to: pt(6.08527, 5.84099), control1: pt(5.79238, 5.07322),     control2: pt(5.79238, 5.5481))
                p2.addCurve(to: pt(7.14594, 5.84099), control1: pt(6.37817, 6.13388),     control2: pt(6.85304, 6.13388))
                p2.addLine(to: pt(11.7066, 1.28033))
                p2.addCurve(to: pt(11.7066, 0.21967), control1: pt(11.9995, 0.987437),    control2: pt(11.9995, 0.512563))
                p2.closeSubpath()
                ctx.fill(p2, with: .color(color))
            }
        }
        .frame(width: double ? 12 : 9, height: 7)
    }
}
