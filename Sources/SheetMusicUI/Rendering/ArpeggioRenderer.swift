import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum ArpeggioRenderer {
    /// Draw a vertical stack of arpeggio "wiggle" segments from `top` to
    /// `bottom`, to the left of the chord. `subtype` selects the optional
    /// arrow glyph at one end.
    static func draw(
        context: inout GraphicsContext,
        top: CGPoint,
        bottom: CGPoint,
        subtype: String?,
        metrics: StaffMetrics
    ) {
        let x = top.x - metrics.sp * 1.5
        var y = top.y
        // Step by ~sp; the wiggle glyph is taller than one staff line
        // but this is a v1 approximation.
        while y <= bottom.y {
            context.drawGlyph(
                SMuFLGlyph.arpeggioWiggle,
                at: CGPoint(x: x, y: y),
                size: metrics.glyphFontSize)
            y += metrics.sp
        }
        switch subtype {
        case "up":
            context.drawGlyph(
                SMuFLGlyph.arpeggioUpArrow,
                at: CGPoint(x: x, y: top.y - metrics.sp),
                size: metrics.glyphFontSize)
        case "down":
            context.drawGlyph(
                SMuFLGlyph.arpeggioDownArrow,
                at: CGPoint(x: x, y: bottom.y + metrics.sp),
                size: metrics.glyphFontSize)
        default:
            break
        }
    }
}
