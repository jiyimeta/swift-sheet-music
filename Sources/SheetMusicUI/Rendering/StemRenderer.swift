#if os(macOS)
import SheetMusicCore
import SwiftUI

@available(macOS 15.0, *)
enum StemRenderer {
    static func draw(
        context: inout GraphicsContext,
        notes: [LayoutChordNote],
        direction: StemDirection,
        duration: NoteDuration,
        isBeamed: Bool,
        beamY: CGFloat?,
        metrics: StaffMetrics
    ) {
        guard !notes.isEmpty else { return }
        // Whole notes are stemless.
        if case .whole = duration { return }
        let xs = notes.map(\.origin.x)
        let ys = notes.map(\.origin.y)
        // Horizontal distance from the notehead center to the stem.
        // Derived from Bravura's published noteheadBlack anchors
        // (stemUpSE.x = 1.18 sp, stemDownNW.x = 0 sp, bbox width = 1.18
        // sp, glyph drawn with `.center` anchor): |stem_x − center| =
        // 0.59 sp. Using exactly that aligns the stem to MuseScore's
        // rendering; the prior 0.65 sp drifted visibly to the outside.
        let stemAttachDx = metrics.sp * 0.59
        let xMin = xs.min() ?? 0
        let xMax = xs.max() ?? 0
        let yTop = ys.min() ?? 0  // higher on screen (smaller y)
        let yBot = ys.max() ?? 0
        let xStem: CGFloat
        let startY: CGFloat
        let endY: CGFloat
        switch direction {
        case .up:
            xStem = xMax + stemAttachDx
            // For beamed chords, stems reach the shared beam y instead of
            // each chord's own natural stem-top — otherwise stems would
            // be truncated below the beam bar.
            startY = beamY ?? (yTop - metrics.defaultStemLength)
            endY = yBot
        case .down:
            xStem = xMin - stemAttachDx
            startY = yTop
            endY = beamY ?? (yBot + metrics.defaultStemLength)
        }
        var path = Path()
        path.move(to: CGPoint(x: xStem, y: startY))
        path.addLine(to: CGPoint(x: xStem, y: endY))
        context.stroke(
            path,
            with: .color(.primary),
            lineWidth: metrics.stemThickness
        )
        // Beamed chords get their flag replaced by a BeamRenderer bar —
        // skip the flag glyph here.
        if isBeamed { return }
        // Flag for isolated short notes.
        if let flag = flagGlyph(for: duration, direction: direction) {
            drawFlag(
                context: &context,
                glyph: flag,
                direction: direction,
                stemX: xStem,
                startY: startY,
                endY: endY,
                metrics: metrics)
        }
    }

    /// Place a flag glyph so its stem-attach anchor lands on the stem
    /// tip. SwiftUI Text anchors act on the font's line-metrics box
    /// (ascent + descent), not on the glyph's ink bounds, so we anchor
    /// `.leading` (left-center) and nudge vertically by ~1 sp — Bravura's
    /// flag glyphs are drawn so their center roughly coincides with the
    /// "one sp into the flag body from the stem tip" point, which is
    /// what engraved scores show.
    private static func drawFlag(
        context: inout GraphicsContext,
        glyph: Character,
        direction: StemDirection,
        stemX: CGFloat,
        startY: CGFloat,
        endY: CGFloat,
        metrics: StaffMetrics
    ) {
        switch direction {
        case .up:
            // Stem-up flag hangs below the stem top. Leading-anchor at
            // ~1 sp below the stem tip puts the flag visual right of
            // the stem with its top roughly at the stem top.
            context.drawGlyph(
                glyph,
                at: CGPoint(x: stemX, y: startY + metrics.sp),
                size: metrics.glyphFontSize,
                anchor: .leading)
        case .down:
            // Stem-down flag rises above the stem bottom — mirror image
            // of the up case.
            context.drawGlyph(
                glyph,
                at: CGPoint(x: stemX, y: endY - metrics.sp),
                size: metrics.glyphFontSize,
                anchor: .leading)
        }
    }

    private static func flagGlyph(
        for dur: NoteDuration, direction: StemDirection
    ) -> Character? {
        switch (dur, direction) {
        case (.eighth, .up): return SMuFLGlyph.flag8thUp
        case (.eighth, .down): return SMuFLGlyph.flag8thDown
        case (.sixteenth, .up): return SMuFLGlyph.flag16thUp
        case (.sixteenth, .down): return SMuFLGlyph.flag16thDown
        case (.thirtySecond, .up): return SMuFLGlyph.flag32ndUp
        case (.thirtySecond, .down): return SMuFLGlyph.flag32ndDown
        case (.sixtyFourth, .up): return SMuFLGlyph.flag64thUp
        case (.sixtyFourth, .down): return SMuFLGlyph.flag64thDown
        default: return nil
        }
    }
}
#endif
