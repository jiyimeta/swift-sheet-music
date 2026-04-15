#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum KeySignatureRenderer {
    // Steps for each accidental in standard engraving order.
    // Sharp order: F♯ C♯ G♯ D♯ A♯ E♯ B♯.
    // Flat order:  B♭ E♭ A♭ D♭ G♭ C♭ F♭.
    // Step values are on a treble staff (middle line = step 0).
    private static let sharpSteps: [Int] = [4, 1, 5, 2, -1, 3, 0]
    private static let flatSteps:  [Int] = [0, 3, -1, 2, -2, 1, -3]

    static func draw(
        context: inout GraphicsContext,
        sharps: Int,
        flats: Int,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let count = max(0, sharps) + max(0, flats)
        guard count > 0 else { return }
        let isSharp = sharps > 0
        let glyph = isSharp
            ? SMuFLGlyph.accidentalSharp
            : SMuFLGlyph.accidentalFlat
        let steps = isSharp ? sharpSteps : flatSteps
        for i in 0..<min(count, steps.count) {
            let step = steps[i]
            let x = origin.x + CGFloat(i) * metrics.sp
            let y = origin.y - CGFloat(step) * metrics.sp / 2
            context.drawGlyph(
                glyph,
                at: CGPoint(x: x, y: y),
                size: metrics.glyphFontSize
            )
        }
    }
}
#endif
