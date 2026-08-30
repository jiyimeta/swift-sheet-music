import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum KeySignatureRenderer {
    /// `naturals` are pre-resolved steps (the layout engine already
    /// matched them to the clef); they are drawn FIRST, so the new
    /// signature — if any — follows the cancellation cluster.
    static func draw(
        context: inout GraphicsContext,
        sharps: Int,
        flats: Int,
        clef: NotatedClef,
        naturals: [Int] = [],
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        let glyph = sharps > 0
            ? SMuFLGlyph.accidentalSharp
            : SMuFLGlyph.accidentalFlat
        let steps = KeySignatureSteps.steps(
            sharps: sharps, flats: flats, clef: clef,
        )
        let advance = KeySignatureSteps.advance(sp: metrics.sp)
        let run = naturals.map { ($0, SMuFLGlyph.accidentalNatural) }
            + steps.map { ($0, glyph) }
        for (i, entry) in run.enumerated() {
            let x = origin.x + CGFloat(i) * advance
            let y = origin.y + KeySignatureSteps.stepDy(
                step: entry.0, sp: metrics.sp,
            )
            context.drawGlyph(
                entry.1,
                at: CGPoint(x: x, y: y),
                size: metrics.glyphFontSize,
            )
        }
    }
}
