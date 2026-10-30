#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// Where the cymbal choke (SMuFL `pictChokeCymbal`, U+E805) is drawn: after the note, at the upper right of the
/// chord's top notehead — where Weinberg / PAS and most published drum parts print it, and where drummers read "stop
/// after this note". MuseScore draws it above the chord, as it does every articulation with no placement variant; the
/// position is layout only, so the model and both file formats keep it an ordinary chord articulation.
///
/// Horizontally the mark clears everything already right of the chord's heads — the heads themselves, a mirrored
/// second, the augmentation dots, an unbeamed up stem's flag. Vertically its baseline sits on the top head's top,
/// whichever way the stem points. The spacing makes room for it (`ColumnInk.markReach`), so neither the next chord
/// nor the barline runs into it.
extension LayoutEngine {
    /// Gap between the rightmost ink the chord already has and the choke's ink, in staff spaces — the distance an
    /// augmentation dot keeps from its head (`DotGeometry`: 1.15 − 0.22 − 0.59 ≈ 0.34 sp).
    static let chokeGapSp: CGFloat = 0.35

    /// How far above the top notehead's center the choke's baseline sits, in staff spaces: on the head's top edge.
    static let chokeBaselineRiseSp: CGFloat = 0.5

    /// Room kept between the choke's ink and whatever follows it on the staff — the next chord's head or accidental,
    /// or the barline — in staff spaces. The note-to-accidental padding `ColumnInk.reach` keeps.
    static let chokeTrailingPaddingSp: CGFloat = 0.35

    /// The choke's `.articulation` element for a chord, drawn at `chokeOrigin`. It keeps the articulation's identity
    /// (`anchor`, kind) so selection treats it like any other mark; `isAbove` only picks its one glyph.
    static func chokeArticulation(
        anchor: VoiceElementID?,
        notes: [LayoutChordNote],
        stem: StemDirection,
        duration: NoteDuration,
        isBeamed: Bool,
        chordX: CGFloat,
        staffMidY: CGFloat,
        metrics: StaffMetrics,
    ) -> LayoutElement {
        .articulation(
            kind: .chokeCymbal,
            origin: chokeOrigin(
                notes: notes, stem: stem, duration: duration, isBeamed: isBeamed,
                chordX: chordX, staffMidY: staffMidY, metrics: metrics,
            ),
            isAbove: articulationForcesAbove(.chokeCymbal),
            anchor: anchor,
        )
    }

    /// Where the choke's glyph is anchored for a chord: its `.articulation` origin, the glyph's `.center` anchor the
    /// renderers draw it at (`LayoutElementShape.smuflGlyphRect` names the ink that lands).
    ///
    /// `notes` are the chord's laid-out heads; `chordX` its column x, the x its unmirrored heads sit at. `isBeamed`
    /// drops the flag, which the beam pass replaces with a beam.
    static func chokeOrigin(
        notes: [LayoutChordNote],
        stem: StemDirection,
        duration: NoteDuration,
        isBeamed: Bool,
        chordX: CGFloat,
        staffMidY: CGFloat,
        metrics: StaffMetrics,
    ) -> CGPoint {
        let sp = metrics.sp
        let (base, dots) = DurationInterpretation.splitNote(duration)
        let headHalf = wideHeadHalfWidth(base, metrics: metrics) ?? StemGeometry.attachDx(sp: sp)
        let perHead = max(headHalf, dotsRight(dots, sp: sp))
        var right = notes.map { $0.origin.x + $0.mirrorDx(stem: stem, sp: sp) + perHead }.max() ?? chordX + perHead
        if stem == .up, !isBeamed, let flag = FlagGlyph.codepoint(duration: base, stem: .up) {
            right = max(right, chordX + StemGeometry.attachDx(sp: sp) + bravuraAdvance(flag, metrics: metrics))
        }
        let ink = chokeInk()
        let baselineY = (notes.map(\.origin.y).min() ?? staffMidY) - chokeBaselineRiseSp * sp
        return CGPoint(
            x: right + chokeGapSp * sp + ink.width * sp / 2,
            y: baselineY - ink.baselineFromCenter * sp,
        )
    }

    /// Column x to the right edge of a choke's ink plus `chokeTrailingPaddingSp`, for the spacing; `0` when `chord`
    /// carries none.
    ///
    /// Measured from the model, before the clef and the beams are known, so it takes the wider case of each: a head
    /// displaced by a second, and an up stem's flag on any flagged value. Both only ever add space.
    static func chokeReach(of chord: Chord, metrics: StaffMetrics) -> CGFloat {
        guard chord.articulations.contains(where: { $0.kind == .chokeCymbal }), !chord.notes.isEmpty else { return 0 }
        let sp = metrics.sp
        let (base, dots) = DurationInterpretation.splitNote(chord.duration)
        let halfHead = StemGeometry.attachDx(sp: sp)
        let displaced = holdsSecond(Array(chord.notes)) ? sp * secondDisplacementSp : 0
        let headRight = wideHeadHalfWidth(base, metrics: metrics) ?? halfHead
        var right = max(headRight, dotsRight(dots, sp: sp)) + displaced
        if let flag = FlagGlyph.codepoint(duration: base, stem: .up) {
            right = max(right, halfHead + bravuraAdvance(flag, metrics: metrics))
        }
        return right + (chokeGapSp + chokeInk().width + chokeTrailingPaddingSp) * sp
    }

    /// The choke glyph's ink width and the baseline's distance below the `.center` anchor, both in staff spaces.
    private static func chokeInk() -> (width: CGFloat, baselineFromCenter: CGFloat) {
        // pointSize 4 ⇒ 1 em = 4 units ⇒ 1 unit = 1 sp, as `LayoutElementShape.smuflGlyphRect` measures it.
        let em = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
        let provider = FontMetrics.provider
        let baselineFromCenter = (provider.ascent(font: em) - provider.descent(font: em)) / 2
        let codepoint = UInt16(truncatingIfNeeded: SMuFLCodepoint.pictChokeCymbal)
        let width = provider.glyphPathBoundingBox(font: em, codepoint: codepoint).map(\.width) ?? 1
        return (width, baselineFromCenter)
    }
}
