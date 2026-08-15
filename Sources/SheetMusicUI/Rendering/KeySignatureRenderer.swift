import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum KeySignatureRenderer {
    static func draw(
        context: inout GraphicsContext,
        sharps: Int,
        flats: Int,
        clef: NotatedClef,
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
        for (i, step) in steps.enumerated() {
            let x = origin.x + CGFloat(i) * advance
            let y = origin.y + KeySignatureSteps.stepDy(
                step: step, sp: metrics.sp,
            )
            context.drawGlyph(
                glyph,
                at: CGPoint(x: x, y: y),
                size: metrics.glyphFontSize,
            )
        }
    }
}
