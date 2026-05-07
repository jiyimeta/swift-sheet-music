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
        guard hasSlash,
              let xMin = notes.map(\.origin.x).min(),
              let xMax = notes.map(\.origin.x).max(),
              let yTop = notes.map(\.origin.y).min(),
              let yBot = notes.map(\.origin.y).max()
        else { return }
        // Slash position must track the rendered stem geometry —
        // anchoring at `stemOrigin` (chord-column center, staff
        // middle Y) misses the stem on both axes when the grace
        // sits off-centre or above/below the staff. Mirrors
        // `StemRenderer.draw` so the slash crosses the actual stem.
        let stemAttachDx = scaled.sp * 0.59
        let stemX: CGFloat
        let stemMidY: CGFloat
        switch stem {
        case .up:
            stemX = xMax + stemAttachDx
            let stemTopY = yTop - scaled.defaultStemLength
            stemMidY = (stemTopY + yBot) / 2
        case .down:
            stemX = xMin - stemAttachDx
            let stemBotY = yBot + scaled.defaultStemLength
            stemMidY = (yTop + stemBotY) / 2
        }
        let glyph = stem == .up
            ? SMuFLGlyph.graceNoteSlashStemUp
            : SMuFLGlyph.graceNoteSlashStemDown
        let glyphSize = scaled.sp * 4
        let bravura = CTFontCreateWithName(
            BravuraFont.familyName as CFString, glyphSize, nil
        )
        let position = CGPoint(
            x: base.x + stemX,
            y: base.y + stemMidY
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
