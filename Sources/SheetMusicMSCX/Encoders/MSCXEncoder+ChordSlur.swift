import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// A chord-anchored spanner's end marker, computed when the voice walker
/// passed the begin chord and waiting for the walk to reach the chord/rest
/// it belongs on.
///
/// MuseScore stores a slur as a *pair* of `<Spanner type="Slur">` children —
/// the begin side on the start chord/rest carrying the payload plus a
/// `<next><location>` offset, a `<prev><location>` marker on the end one.
/// Only the begin side is modeled (`Chord.spanners`); this is how the end
/// side is put back.
///
/// The target is expressed the way the encoder actually walks: `measuresAway`
/// counts measure boundaries still to cross in this voice, `fraction` is the
/// position within the target measure. `prevMeasures` / `prevFractions` are
/// the marker's own payload, already negated from the begin side's `<next>`.
struct MSCXPendingSlurEnd: Sendable, Equatable {
    var measuresAway: Int
    var fraction: Fraction
    var rawType: String
    var prevMeasures: Int
    var prevFractions: Fraction?

    /// The marker element for this record.
    func marker(options: MSCXEncoderOptions) -> XMLTreeNode {
        Spanner.chordAnchoredEndMarker(
            rawType: rawType,
            measures: prevMeasures,
            fractions: prevFractions,
            options: options,
        )
    }

    /// Carry the still-unplaced records into the next measure of the same
    /// voice: everything targeting *this* measure (`measuresAway == 0`) has
    /// had its chance and is dropped, the rest move one measure closer.
    ///
    /// Dropping is the deliberate fallback for an end the walk cannot reach —
    /// an offset past the end of the score, or (see
    /// `Chord.pendingSlurEnds(at:)`) a cross-voice slur whose partner lives
    /// in a voice this walk never visits. It matches how the tie and
    /// guitar-bend location math treat an endpoint the encoder cannot see:
    /// the marker is omitted, nothing throws, and the begin side still
    /// round-trips its own offsets.
    static func carriedToNextMeasure(
        _ pending: [MSCXPendingSlurEnd],
    ) -> [MSCXPendingSlurEnd] {
        pending
            .filter { $0.measuresAway > 0 }
            .map {
                var next = $0
                next.measuresAway -= 1
                return next
            }
    }
}

extension Chord {
    /// The begin-side `<Spanner>` markers this chord/rest carries.
    func slurBeginMarkers(options: MSCXEncoderOptions) -> [XMLTreeNode] {
        spanners.map { $0.encodeChordAnchoredBegin(options: options) }
    }

    /// The end markers this chord's begin sides ask for, given the chord's
    /// own position within its measure.
    ///
    /// The target follows the same `<location>` semantics every other writer
    /// in this module uses: `measures` counts measure boundaries, `fractions`
    /// is added to the source's position within its own bar. So the end sits
    /// `nextMeasuresOffset` measures on, at `position + nextFractionsOffset`.
    ///
    /// **Cross-voice slurs are not placed.** MuseScore's `<location>` can
    /// also carry `<voices>`, and `slur_ms3_exchangevoices.mscx:221-230`
    /// holds a slur that hops voices with `<voices>-1</voices>`. That field
    /// is not modeled — `Spanner.decode` drops it — and this encoder walks
    /// one voice at a time, so the marker cannot be handed to the other
    /// voice's chord anyway. The begin side still round-trips its own
    /// offsets; the `<prev>` lands on whatever chord sits at the target
    /// position *in the same voice*, or is dropped when none does.
    ///
    /// A target at or before the chord's own position within the same
    /// measure is unreachable by a forward-only walk and is dropped rather
    /// than mis-placed.
    func pendingSlurEnds(at position: Fraction) -> [MSCXPendingSlurEnd] {
        spanners.compactMap { spanner in
            let fractions = spanner.nextFractionsOffset
                ?? Fraction(numerator: 0, denominator: 1)
            let target = position + fractions
            let unreachableInThisMeasure = spanner.nextMeasuresOffset == 0
                && !Self.isStrictlyAfter(target, position)
            if unreachableInThisMeasure { return nil }
            return MSCXPendingSlurEnd(
                measuresAway: spanner.nextMeasuresOffset,
                fraction: target,
                rawType: spanner.rawType,
                prevMeasures: -spanner.nextMeasuresOffset,
                prevFractions: spanner.nextFractionsOffset.map {
                    Fraction(numerator: -$0.numerator, denominator: $0.denominator)
                },
            )
        }
    }

    /// `Fraction` is `Hashable` but not `Comparable`; cross-multiplying is
    /// safe because denominators are always positive.
    private static func isStrictlyAfter(_ lhs: Fraction, _ rhs: Fraction) -> Bool {
        lhs.numerator * rhs.denominator > rhs.numerator * lhs.denominator
    }
}
