#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// Horizontal collision floors between neighboring note columns.
///
/// The spacing weights (`durationWidth` plus the lyric / grace / harmony demands folded into them) say how far apart
/// two columns SHOULD be. They say nothing about what hangs off a column's sides, so an accidental — drawn left of
/// its notehead, inside the gap before its column — collides with the previous note whenever that gap is squeezed
/// toward its weight: at a system's minimum width, or when a host's `systemStretch` asks for dense music.
///
/// MuseScore keeps the two apart. `HorizontalSpacing::spaceAgainstPreviousSegments` places each segment at
/// `max(previous + naturalWidth, previous + minHorizontalDistance(shapes))`, where the shape of a chord includes its
/// accidentals and the distance is padded from `rendering/paddingtable.cpp`. Spacing density
/// (`Sid::spacingDensity`, and a measure's user stretch) divides only the natural, duration-driven width; the
/// shape distance is a floor no density can cross. Justification then spreads the leftover space with springs that
/// leave a gap already pushed past its natural width alone until the rest catch up.
///
/// This file is that floor reduced to what collides in practice: per staff, the previous column's noteheads, dots
/// and rests on the right against the next column's accidentals on the left. `TickAggregate.gapFloors` carries the
/// result, and every consumer of the aggregate honors it as `max(floor, k · weight)` — `tickColumns` when it places
/// the columns, `crossStaffMinimumMeasureWidth` at `k = 1`, and `packSystems` at the host's stretch.
///
/// Deliberately conservative where the engine cannot know the answer before placement: stem direction depends on
/// the clef, so a chord holding a second is assumed to have a notehead displaced to BOTH sides, and there is no
/// vertical test — an accidental a sixth below the previous note still keeps its distance, where MuseScore would
/// kern it underneath. Both only ever add space.
extension LayoutEngine {
    /// How far one staff's chords and rests at one tick reach either side of their column's x, in points.
    struct ColumnInk: Equatable {
        /// Column x to the leftmost accidental's left edge; `0` when the column draws no accidental.
        var left: CGFloat = 0
        /// Column x to the rightmost notehead / dot / rest ink, plus the padding MuseScore keeps between that ink and
        /// a following accidental (`paddingtable.cpp`: note or dot → accidental 0.35 sp, rest → accidental 0.45 sp).
        var reach: CGFloat = 0

        mutating func formUnion(_ other: ColumnInk) {
            left = max(left, other.left)
            reach = max(reach, other.reach)
        }
    }

    /// Horizontal displacement of a notehead pushed to the far side of its stem by a second (Bravura
    /// `noteheadBlack`, the same 1.18 sp `LayoutChordNote.mirrorDx` shifts by).
    private static let secondDisplacementSp: CGFloat = 1.18

    static func columnInk(of chord: Chord, metrics: StaffMetrics) -> ColumnInk {
        let sp = metrics.sp
        let (base, dots) = DurationInterpretation.split(chord.duration)
        guard !chord.notes.isEmpty else {
            let glyph = RestGlyph.codepoint(duration: chord.duration)
            let halfWidth = bravuraAdvance(glyph, metrics: metrics) / 2
            return ColumnInk(reach: max(halfWidth, dotsRight(dots, sp: sp)) + sp * 0.45)
        }
        let displaced = holdsSecond(chord) ? sp * secondDisplacementSp : 0
        let halfHead = StemGeometry.attachDx(sp: sp)
        var left: CGFloat = 0
        for note in chord.notes {
            guard let accidental = note.accidental else { continue }
            var advance = bravuraAdvance(AccidentalGlyph.codepoint(accidental), metrics: metrics)
            if let enclosure = AccidentalGlyph.enclosure(note.accidentalBracket) {
                advance += bravuraAdvance(enclosure.left, metrics: metrics)
                    + bravuraAdvance(enclosure.right, metrics: metrics)
            }
            left = max(left, halfHead + displaced + AccidentalPlacement.gapSp * sp + advance)
        }
        // A whole note's head is wider than the black one `attachDx` halves (Bravura `noteheadWhole` 1.688 sp).
        let headRight = base == .whole ? sp * 1.688 / 2 : halfHead
        let right = max(headRight, dotsRight(dots, sp: sp)) + displaced
        return ColumnInk(left: left, reach: right + sp * 0.35)
    }

    /// Clearance between a clef written in the middle of a bar and the leftmost accidental of the column it precedes,
    /// in staff spaces — MuseScore's clef-to-accidental padding.
    static let midMeasureClefGapSp: CGFloat = 0.6

    /// The same clearance when that column has no accidental and the clef faces its notehead — MuseScore's
    /// `Sid::clefKeyRightMargin`.
    static let midMeasureClefNoteGapSp: CGFloat = 0.8

    /// Clearance kept on the clef's other side, beyond the previous column's own `reach` padding.
    static let midMeasureClefLeadSp: CGFloat = 0.4

    /// The size of a clef written after a bar's first chord or rest against a full one — MuseScore's
    /// `Sid::smallClefMag`. A clef at the head of a bar stays full size.
    static let smallClefMag: CGFloat = 0.8

    /// Clearance between a clef written after a bar's last chord or rest and the barline it stands before —
    /// MuseScore's `Sid::clefBarlineDistance`.
    static let clefBarlineDistanceSp: CGFloat = 0.5

    /// A small clef's advance — the width every renderer draws it at (`LayoutElement.clef`'s `mag`).
    static func smallClefAdvance(rawType: String, metrics: StaffMetrics) -> CGFloat {
        let glyph = ClefGlyph.glyph(for: NotatedClef(rawType: rawType)).codepoint
        return bravuraAdvance(glyph, metrics: metrics) * smallClefMag
    }

    /// Column x to the CENTER of a clef written in the middle of a bar, before the chord or rest at that column —
    /// where the clef is drawn (`placeMeasureElements`; a clef's origin is its glyph's center).
    ///
    /// A mid-bar clef used to be drawn AT the next column, on top of the note it governs, with no room made for it:
    /// the layout gave it the column's x and the spacing gave it nothing. MuseScore gives it a segment of its own
    /// before the chord's; here it is the left reach of the chord's column (`midMeasureClefReach`), so the collision
    /// floor that keeps an accidental off the previous note keeps the clef off it too, at any stretch.
    ///
    /// `element` is the chord or rest the clef precedes in its own voice; its accidentals push the clef further left.
    static func midMeasureClefOffset(rawType: String, before element: Chord, metrics: StaffMetrics) -> CGFloat {
        clefClearance(before: element, metrics: metrics) + smallClefAdvance(rawType: rawType, metrics: metrics) / 2
    }

    /// How far left of the column a mid-bar clef's ink reaches, plus `midMeasureClefLeadSp` — the column's
    /// `ColumnInk.left` while one precedes it (`aggregatedTickWeights`).
    static func midMeasureClefReach(rawType: String, before element: Chord, metrics: StaffMetrics) -> CGFloat {
        clefClearance(before: element, metrics: metrics) + smallClefAdvance(rawType: rawType, metrics: metrics)
            + midMeasureClefLeadSp * metrics.sp
    }

    /// The room a clef written after a bar's last chord or rest takes before the barline: its small glyph, the
    /// clearance from the barline, and the lead kept from the last column. MuseScore puts such a clef — its usual
    /// spelling of a clef change at the next barline — in a segment at the end of the bar, before the barline.
    static func barEndClefWidth(rawType: String, metrics: StaffMetrics) -> CGFloat {
        smallClefAdvance(rawType: rawType, metrics: metrics)
            + (clefBarlineDistanceSp + midMeasureClefLeadSp) * metrics.sp
    }

    /// `barEndClefWidth(rawType:metrics:)` for the visible clef `voice` writes after its last chord or rest — `0`
    /// when it writes none there.
    static func barEndClefWidth(in voice: Voice, metrics: StaffMetrics) -> CGFloat {
        let elements = voice.elements.values
        guard let lastTimed = elements.lastIndex(where: { if case .chord = $0 { true } else { false } }) else {
            return 0
        }
        let clef = elements[(lastTimed + 1)...].lazy.compactMap { element -> Clef? in
            if case let .clef(clef) = element, clef.visible { clef } else { nil }
        }.last
        return clef.map { barEndClefWidth(rawType: $0.concertClefType, metrics: metrics) } ?? 0
    }

    /// Column x to where a clef's ink must end before `element`'s column: clear of its leftmost accidental by
    /// `midMeasureClefGapSp`, else of its notehead by `midMeasureClefNoteGapSp`.
    private static func clefClearance(before element: Chord, metrics: StaffMetrics) -> CGFloat {
        let sp = metrics.sp
        let accidentals = columnInk(of: element, metrics: metrics).left
        return accidentals > 0
            ? accidentals + midMeasureClefGapSp * sp
            : StemGeometry.attachDx(sp: sp) + midMeasureClefNoteGapSp * sp
    }

    /// Per-gap collision floors for an aggregate's gaps: `floors[i]` is the least distance column `i` may sit from
    /// column `i + 1`.
    ///
    /// - Parameter inks: one table per staff, tick → that staff's ink at the tick. Collisions are checked between a
    ///   staff's consecutive ticks only; another staff's columns in between widen the span but never collide.
    ///   When they do sit in between, the gaps before the last one are only known to be at least their weight, so
    ///   the whole deficit is charged to the gap right before the accidental.
    static func collisionFloors(
        inks: [[Int: ColumnInk]],
        sortedTicks: [Int],
        gapWeights: [CGFloat],
    ) -> [CGFloat] {
        var floors = [CGFloat](repeating: 0, count: gapWeights.count)
        let index = Dictionary(uniqueKeysWithValues: sortedTicks.enumerated().map { ($1, $0) })
        for staffInks in inks {
            let ticks = staffInks.keys.sorted()
            for (previousTick, tick) in zip(ticks, ticks.dropFirst()) {
                guard let ink = staffInks[tick], ink.left > 0,
                      let previous = staffInks[previousTick],
                      let from = index[previousTick], let to = index[tick], to > from
                else { continue }
                let spanned = gapWeights[from ..< to - 1].reduce(0, +)
                floors[to - 1] = max(floors[to - 1], previous.reach + ink.left - spanned)
            }
        }
        return floors
    }

    /// The gaps that fill `content`: each gap is `max(floor, k · weight)`, with the one `k` that makes them sum to
    /// `content` — MuseScore's springs with pre-tension, where a gap an accidental has already pushed open takes no
    /// more space until every other gap has stretched as far.
    ///
    /// `content` must be at least `Σ max(floor, weight)` (`TickAggregate.minimumContentWidth`); every caller floors
    /// it there, so `k` never drops below 1.
    static func filledGaps(
        weights: [CGFloat], floors: [CGFloat], content: CGFloat,
    ) -> [CGFloat] {
        var atFloor = weights.indices.map { weights[$0] == 0 && floors[$0] > 0 }
        var k: CGFloat = 0
        while true {
            var fixed: CGFloat = 0
            var free: CGFloat = 0
            for i in weights.indices {
                if atFloor[i] { fixed += floors[i] } else { free += weights[i] }
            }
            guard free > 0 else { break }
            k = max(0, (content - fixed) / free)
            var changed = false
            for i in weights.indices where !atFloor[i] && floors[i] > k * weights[i] {
                atFloor[i] = true
                changed = true
            }
            if !changed { break }
        }
        return weights.indices.map { atFloor[$0] ? floors[$0] : k * weights[$0] }
    }

    // MARK: - Private

    private static let trebleClef = NotatedClef(rawType: "G")

    private static func dotsRight(_ dots: Int, sp: CGFloat) -> CGFloat {
        guard dots > 0 else { return 0 }
        return sp * (DotGeometry.firstOffsetSp + CGFloat(dots - 1) * DotGeometry.spacingSp + DotGeometry.radiusSp)
    }

    /// Whether any two of `chord`'s notes sit a step or less apart — the condition `applyChordMirroring` flips a
    /// notehead to the other side of the stem on. Steps are taken under a treble clef: only their differences matter,
    /// and those are the same under every clef.
    private static func holdsSecond(_ chord: Chord) -> Bool {
        guard chord.notes.count > 1 else { return false }
        let steps = chord.notes.map {
            PitchStaffPosition.step(midiPitch: $0.pitch, tpc: $0.tpc, clef: trebleClef).step
        }.sorted()
        return zip(steps, steps.dropFirst()).contains { $1 - $0 < 2 }
    }

    /// A glyph's advance, measured the way the renderers measure it (`AccidentalPlacement.leftEdgeX` takes the
    /// accidental's advance; a rest is centered on its column).
    private static func bravuraAdvance(_ codepoint: UInt32, metrics: StaffMetrics) -> CGFloat {
        guard let scalar = UnicodeScalar(codepoint) else { return 0 }
        return FontMetrics.provider.typographicWidth(
            text: String(Character(scalar)),
            font: LayoutFont(face: SMuFLFamily.bravura, pointSize: metrics.glyphFontSize),
        )
    }
}
