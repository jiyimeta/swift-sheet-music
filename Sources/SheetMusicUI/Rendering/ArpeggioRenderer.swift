import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum ArpeggioRenderer {
    /// Draw a vertical stack of arpeggio "wiggle" segments from `top` to
    /// `bottom`, to the left of the chord. `subtype` selects the optional
    /// arrow glyph at one end.
    ///
    /// SMuFL `wiggleArpeggiatoUp` (and the arrow variants) are drawn
    /// horizontally in the font; vertical arpeggios rotate each segment
    /// -90° around its anchor. Mirrors MuseScore's `Arpeggio::draw`
    /// (`painter->rotate(-90)`).
    static func draw(
        context: inout GraphicsContext,
        top: CGPoint,
        bottom: CGPoint,
        subtype: String?,
        metrics: StaffMetrics,
    ) {
        let x = top.x - metrics.sp * 1.5
        var y = top.y
        while y <= bottom.y {
            drawRotated(
                &context,
                glyph: SMuFLGlyph.arpeggioWiggle,
                at: CGPoint(x: x, y: y),
                size: metrics.glyphFontSize,
            )
            y += metrics.sp
        }
        switch subtype {
        case "up":
            drawRotated(
                &context,
                glyph: SMuFLGlyph.arpeggioUpArrow,
                at: CGPoint(x: x, y: top.y - metrics.sp),
                size: metrics.glyphFontSize,
            )
        case "down":
            drawRotated(
                &context,
                glyph: SMuFLGlyph.arpeggioDownArrow,
                at: CGPoint(x: x, y: bottom.y + metrics.sp),
                size: metrics.glyphFontSize,
            )
        default:
            break
        }
    }

    private static func drawRotated(
        _ context: inout GraphicsContext,
        glyph: Character,
        at origin: CGPoint,
        size: CGFloat,
    ) {
        context.drawLayer { ctx in
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.rotate(by: .degrees(-90))
            ctx.drawGlyph(glyph, at: .zero, size: size)
        }
    }
}
