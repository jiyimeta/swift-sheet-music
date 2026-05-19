import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum KeySignatureRenderer {
    static func draw(
        context: inout GraphicsContext,
        sharps: Int,
        flats: Int,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        let count = max(0, sharps) + max(0, flats)
        guard count > 0 else { return }
        let isSharp = sharps > 0
        let glyph = isSharp
            ? SMuFLGlyph.accidentalSharp
            : SMuFLGlyph.accidentalFlat
        let steps = isSharp
            ? KeySignatureSteps.sharps
            : KeySignatureSteps.flats
        let advance = KeySignatureSteps.advance(sp: metrics.sp)
        for i in 0 ..< min(count, steps.count) {
            let step = steps[i]
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
