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
