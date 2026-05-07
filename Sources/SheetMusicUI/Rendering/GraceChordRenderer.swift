import CoreText
import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, iOS 16.0, *)
extension ScoreLayerBuilder {
    // swiftlint:disable:next function_parameter_count
    /// Draw a `LayoutElement.graceChord` by recursively reusing the
    /// main-chord renderers at a `mag`-scaled `StaffMetrics`.
    /// Acciaccatura adds a SMuFL slash glyph over the stem.
    static func drawGraceChord(
        notes: [LayoutChordNote],
        duration: NoteDuration,
        stem: StemDirection,
        stemOrigin: CGPoint,
        hasSlash: Bool,
        mag: CGFloat,
        base: CGPoint,
        metrics: StaffMetrics,
        height: CGFloat,
        context: inout BuildContext,
        into parent: CALayer
    ) {
        // Build a scaled `StaffMetrics` so notehead / stem / flag
        // widths follow `mag`. Every dimension on `StaffMetrics`
        // derives from `sp = staffSize/4`, so feeding `staffSize *
        // mag` shrinks every glyph proportionally. The grace's
        // y-positions (already in parent-staff coordinates from the
        // layout step) are passed through untouched, so the glyphs
        // sit on the parent staff — only the GLYPH sizes shrink.
        let scaled = StaffMetrics(staffSize: metrics.staffHeight * mag)
        drawChord(
            notes: notes, duration: duration, stem: stem,
            stemOrigin: stemOrigin, isBeamed: false,
            base: base, metrics: scaled, height: height,
            context: &context, into: parent
        )
        guard hasSlash else { return }
        let glyph = stem == .up
            ? SMuFLGlyph.graceNoteSlashStemUp
            : SMuFLGlyph.graceNoteSlashStemDown
        let glyphSize = scaled.sp * 4
        let bravura = CTFontCreateWithName(
            BravuraFont.familyName as CFString, glyphSize, nil
        )
        // Slash sits ~1.5 sp up the stem from the notehead end.
        let dy: CGFloat = stem == .up ? -scaled.sp * 1.5 : scaled.sp * 1.5
        let position = CGPoint(
            x: base.x + stemOrigin.x,
            y: base.y + stemOrigin.y + dy
        )
        if let layer = textLayer(
            text: String(glyph), at: position,
            size: glyphSize, italic: false,
            anchor: CGPoint(x: 0.5, y: 0.5),
            font: bravura,
            height: height
        ) {
            parent.addSublayer(layer)
        }
    }
}
