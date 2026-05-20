import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
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
        let segments = ArpeggioGeometry.segments(
            top: top, bottom: bottom,
            subtype: subtype, sp: metrics.sp,
        )
        for segment in segments {
            // swiftlint:disable:next force_unwrapping
            let glyph = Character(UnicodeScalar(segment.codepoint)!)
            drawRotated(
                &context,
                glyph: glyph,
                at: segment.origin,
                size: metrics.glyphFontSize,
            )
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
