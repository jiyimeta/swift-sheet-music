import SwiftUI

/// Build a non-negative rectangle from two arbitrary corner
/// points. The drag gesture's `startLocation` and `location` can
/// produce any of the four directional drags; this normalises so
/// both ends of the dragged region appear in the resulting rect.
func makeMarqueeRect(from a: CGPoint, to b: CGPoint) -> CGRect {
    CGRect(
        x: min(a.x, b.x),
        y: min(a.y, b.y),
        width: abs(b.x - a.x),
        height: abs(b.y - a.y))
}

/// Translucent rectangle + dashed stroke drawn over `ScoreView`
/// while the user is dragging a marquee selection. `rect` is `nil`
/// outside an active drag, in which case nothing renders.
struct MarqueeOverlay: View {
    let rect: CGRect?

    var body: some View {
        GeometryReader { _ in
            if let rect {
                ZStack {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.12))
                    Rectangle()
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(
                                lineWidth: 1.5,
                                dash: [5, 3]))
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
            }
        }
    }
}
