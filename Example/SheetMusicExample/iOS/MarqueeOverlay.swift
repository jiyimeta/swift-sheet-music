#if !os(macOS)
import SwiftUI

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
#endif
