import CoreText
import SheetMusicCore
import SheetMusicLayout
import SheetMusicLayoutApple
import SwiftUI

@available(macOS 15.0, *)
enum StemRenderer {
    static func draw( // swiftlint:disable:this function_parameter_count
        context: inout GraphicsContext,
        notes: [LayoutChordNote],
        direction: StemDirection,
        duration: NoteDuration,
        isBeamed: Bool,
        beamY: CGFloat?,
        stemExtension: CGFloat = 0,
        metrics: StaffMetrics,
    ) {
        // Whole notes are stemless.
        if case .whole = duration { return }
        guard let geometry = StemGeometry.compute(
            noteOrigins: notes.map(\.origin),
            direction: direction,
            beamY: beamY,
            defaultStemLength: metrics.defaultStemLength,
            stemExtension: stemExtension,
            sp: metrics.sp,
        ) else { return }
        let xStem = geometry.xStem
        let startY = geometry.startY
        let endY = geometry.endY
        var path = Path()
        path.move(to: CGPoint(x: xStem, y: startY))
        path.addLine(to: CGPoint(x: xStem, y: endY))
        context.stroke(
            path,
            with: .color(.primary),
            lineWidth: metrics.stemThickness,
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
                metrics: metrics,
            )
        }
    }

    /// Place a flag glyph so its stem-attach anchor lands on the stem
    /// tip, matching MuseScore's use of Bravura's `stemUpNW` /
    /// `stemDownSW` glyph anchors.
    ///
    /// Bravura metadata values (in sp):
    ///   flag8thUp.stemUpNW    = [0, -0.04]    (~0 → glyph origin)
    ///   flag8thDown.stemDownSW = [0, 0.132]   (~0 → glyph origin)
    /// In both cases the attach point sits essentially on the glyph's
    /// baseline origin, so we draw the flag with its baseline on the
    /// stem tip.
    ///
    /// SwiftUI `.topLeading` places the text-bounds TOP at the anchor
    /// y; the baseline lives at `anchor_y + ascent`. Querying Bravura's
    /// actual ascent via CoreText (instead of guessing from sp) is the
    /// only way to position the flag precisely because the font's
    /// line-metrics include padding above the glyph's ink.
    private static func drawFlag(
        context: inout GraphicsContext,
        glyph: Character,
        direction: StemDirection,
        stemX: CGFloat,
        startY: CGFloat,
        endY: CGFloat,
        metrics: StaffMetrics,
    ) {
        let tipY: CGFloat = direction == .up ? startY : endY
        let font = cachedBravuraFont(size: metrics.glyphFontSize)
        let ascent = CTFontGetAscent(font)
        context.drawGlyph(
            glyph,
            at: CGPoint(x: stemX, y: tipY - ascent),
            size: metrics.glyphFontSize,
            anchor: .topLeading,
        )
    }

    // CTFont handle is shared per font-size. Creating CTFonts isn't
    // free, so cache the most recent one — stem/flag drawing hits this
    // on every chord.
    private nonisolated(unsafe) static var cachedFont: CTFont?
    private nonisolated(unsafe) static var cachedSize: CGFloat = 0

    private static func cachedBravuraFont(size: CGFloat) -> CTFont {
        if let font = cachedFont, cachedSize == size { return font }
        let font = CTFontCreateWithName(
            BravuraFont.familyName as CFString, size, nil,
        )
        cachedFont = font
        cachedSize = size
        return font
    }

    private static func flagGlyph(
        for dur: NoteDuration, direction: StemDirection,
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
