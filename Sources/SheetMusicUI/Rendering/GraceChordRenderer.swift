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
        // Slash endpoints come from the shared `GraceSlashGeometry`
        // (Bravura `graceNoteSlash` anchor table) so this renderer and the
        // Android bridge draw the identical slash. `scaled` already folds
        // in `mag`, so the geometry matches the reduced grace stem.
        guard let slash = GraceSlashGeometry.slash(
            noteOrigins: notes.map(\.origin),
            stem: stem,
            sp: scaled.sp,
            defaultStemLength: scaled.defaultStemLength,
            stemThickness: scaled.stemThickness,
        ) else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(
            x: base.x + slash.from.x, y: base.y + slash.from.y,
        ))
        path.addLine(to: CGPoint(
            x: base.x + slash.to.x, y: base.y + slash.to.y,
        ))
        // Match the rendered grace stem's weight so the slash reads
        // at on-screen DPIs. MuseScore's `stemSlashThickness =
        // 0.125 sp × mag` aliases below one device pixel.
        parent.addSublayer(strokeLayer(
            path: path, height: height,
            lineWidth: scaled.stemThickness,
        ))
    }
}
