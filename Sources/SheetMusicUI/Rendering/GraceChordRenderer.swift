import CoreGraphics
import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, *)
extension ScoreLayerBuilder {
    // swiftlint:disable:next function_parameter_count
    /// Draw a `LayoutElement.graceChord` by recursively reusing the
    /// main-chord renderers at a `mag`-scaled `StaffMetrics`.
    /// Acciaccatura adds a stroked slash line across the stem.
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
        into parent: CALayer,
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
            context: &context, into: parent,
        )
        guard hasSlash else { return }
        drawAcciaccaturaSlash(
            notes: notes, stem: stem,
            base: base, scaled: scaled, height: height,
            into: parent,
        )
    }

    /// Acciaccatura slash position. Uses Bravura's
    /// `graceNoteSlash{NE,SW,NW,SE}` glyph anchors (from
    /// `bravura_metadata.json`) instead of MuseScore's
    /// algorithmic placement (`tlayout.cpp:5249`'s
    /// `stemSlashPosition = 2 sp`, `stemSlashAngle = 40°`). The
    /// anchors are the font designer's intended slash endpoints and
    /// produce a crossing point biased toward the notehead — the
    /// algorithm-derived placement crosses noticeably closer to the
    /// flag than the engraving convention. Anchors are in glyph
    /// em-units with math y-axis (y > 0 = up); 1 em = 1 sp at
    /// glyph rendering size, so multiplying by `scaled.sp` gives
    /// the on-screen pixel offset relative to the stem tip.
    private static func drawAcciaccaturaSlash(
        notes: [LayoutChordNote],
        stem: StemDirection,
        base: CGPoint,
        scaled: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        guard let xMin = notes.map(\.origin.x).min(),
              let xMax = notes.map(\.origin.x).max(),
              let yTop = notes.map(\.origin.y).min(),
              let yBot = notes.map(\.origin.y).max()
        else { return }
        // Stem geometry — match `ScoreLayerBuilder+Chord.drawStem`
        // exactly so the slash crosses the rendered stem.
        let stemAttachDx = scaled.sp * 0.59 - scaled.stemThickness / 2
        let stemX: CGFloat
        let stemTipY: CGFloat
        // Bravura `graceNoteSlash` endpoints in em-units, math y.
        // First tuple = SW (or NW for stem-down) bottom/top-left
        // end; second = NE (or SE) top/bottom-right end.
        let endA: (x: CGFloat, y: CGFloat)
        let endB: (x: CGFloat, y: CGFloat)
        switch stem {
        case .up:
            stemX = xMax + stemAttachDx
            stemTipY = yTop - scaled.defaultStemLength
            // flag8thUp: graceNoteSlashSW / graceNoteSlashNE.
            endA = (-0.644, -2.456)
            endB = (1.284, -0.796)
        case .down:
            stemX = xMin - stemAttachDx
            stemTipY = yBot + scaled.defaultStemLength
            // flag8thDown: graceNoteSlashNW / graceNoteSlashSE.
            endA = (-0.596, 2.168)
            endB = (1.328, 0.628)
        }
        // Convert anchor (x, math-y) → screen (x, y-down), anchored
        // at the stem tip and scaled by `scaled.sp` (= 1 em).
        let startX = stemX + endA.x * scaled.sp
        let startY = stemTipY - endA.y * scaled.sp
        let endX = stemX + endB.x * scaled.sp
        let endY = stemTipY - endB.y * scaled.sp
        let path = CGMutablePath()
        path.move(to: CGPoint(x: base.x + startX, y: base.y + startY))
        path.addLine(to: CGPoint(x: base.x + endX, y: base.y + endY))
        // Match the rendered grace stem's weight so the slash reads
        // at on-screen DPIs. MuseScore's `stemSlashThickness =
        // 0.125 sp × mag` aliases below one device pixel.
        parent.addSublayer(strokeLayer(
            path: path, height: height,
            lineWidth: scaled.stemThickness,
        ))
    }
}
