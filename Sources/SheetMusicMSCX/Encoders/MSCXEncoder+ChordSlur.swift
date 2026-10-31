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
/// Only the begin side is modeled (`Chord.spanners`, `GraceChord.spanners`);
/// this is how the end side is put back.
///
/// The target is expressed the way the encoder actually walks: `measuresAway`
/// counts measure boundaries still to cross in this voice, `fraction` is the
/// position within the target measure, and `targetGraceIndex` picks one of
/// the target chord's graces (its MuseScore `<grace>` index) instead of the
/// chord itself. `prevMeasures` / `prevFractions` are the marker's own
/// payload, already negated from the begin side's `<next>`, and
/// `prevGraceIndex` is the begin side's grace index when it starts on one.
struct MSCXPendingSlurEnd: Sendable, Equatable {
    var measuresAway: Int
    var fraction: Fraction
    var targetGraceIndex: Int?
    var rawType: String
    var prevMeasures: Int
    var prevFractions: Fraction?
    var prevGraceIndex: Int?

    /// The marker element for this record. Version-independent: MuseScore's
    /// single `Location` writer has emitted `<measures>` before `<fractions>`
    /// in every era — see `Spanner.relativeLocationChildren`.
    func marker() -> XMLTreeNode {
        Spanner.chordAnchoredEndMarker(
            rawType: rawType,
            measures: prevMeasures,
            fractions: prevFractions,
            grace: prevGraceIndex,
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

/// The end markers that land on one chord's own run — its graces and the chord itself — because a slur begun in
/// that same run ends there: an acciaccatura slurred into its principal note, or a chord slurred into its own
/// after-grace. The forward walk cannot leave these for later, since MuseScore writes every grace of a run ahead of
/// its chord, so the run is resolved as a unit before any of it is written.
struct MSCXRunSlurEnds {
    /// Markers for the chord itself.
    var onChord: [XMLTreeNode] = []
    /// Markers keyed by the MuseScore `<grace>` index of the grace they belong in.
    var onGrace: [Int: [XMLTreeNode]] = [:]
}

extension Chord {
    /// The begin-side `<Spanner>` markers this chord/rest carries.
    func slurBeginMarkers(options: MSCXEncoderOptions) -> [XMLTreeNode] {
        spanners.map { $0.encodeChordAnchoredBegin(options: options) }
    }

    /// Every begin side this chord's run carries, each with the MuseScore `<grace>` index of the grace it starts on
    /// (`nil` for the chord itself).
    private var runSlurBegins: [(spanner: Spanner, beginGrace: Int?)] {
        var begins = spanners.map { (spanner: $0, beginGrace: Int?.none) }
        for (index, grace) in graceNotesBefore.enumerated() {
            let beginGrace = museScoreGraceIndex(side: .before, index: index)
            begins += grace.spanners.map { (spanner: $0, beginGrace: beginGrace) }
        }
        for (index, grace) in graceNotesAfter.enumerated() {
            let beginGrace = museScoreGraceIndex(side: .after, index: index)
            begins += grace.spanners.map { (spanner: $0, beginGrace: beginGrace) }
        }
        return begins
    }

    /// Whether `spanner`'s end lies in the same chord's run as its begin: no measure and no fraction offset. Only the
    /// grace index can then tell the two ends apart.
    private static func endsInOwnRun(_ spanner: Spanner) -> Bool {
        spanner.nextMeasuresOffset == 0 && (spanner.nextFractionsOffset?.numerator ?? 0) == 0
    }

    /// The end markers for slurs that begin and end within this chord's own run — see `MSCXRunSlurEnds`.
    ///
    /// An end naming no grace of this chord, or naming the very element the slur begins on, is a slur MuseScore
    /// could not draw either; it gets no marker, and its begin side still round-trips.
    func runSlurEnds() -> MSCXRunSlurEnds {
        var ends = MSCXRunSlurEnds()
        for (spanner, beginGrace) in runSlurBegins where Self.endsInOwnRun(spanner) {
            guard spanner.nextGraceIndex != beginGrace else { continue }
            let marker = Spanner.chordAnchoredEndMarker(
                rawType: spanner.rawType, measures: 0, fractions: spanner.nextFractionsOffset, grace: beginGrace,
            )
            if let target = spanner.nextGraceIndex {
                guard grace(atMuseScoreGraceIndex: target) != nil else { continue }
                ends.onGrace[target, default: []].append(marker)
            } else {
                ends.onChord.append(marker)
            }
        }
        return ends
    }

    /// The end markers this chord's begin sides ask for, given the chord's
    /// own position within its measure — its graces' begin sides included,
    /// since a grace shares the chord's tick.
    ///
    /// The target follows the same `<location>` semantics every other writer
    /// in this module uses: `measures` counts measure boundaries, `fractions`
    /// is added to the source's position within its own bar. So the end sits
    /// `nextMeasuresOffset` measures on, at `position + nextFractionsOffset`.
    /// A slur ending within this chord's own run is not pending at all — see
    /// `runSlurEnds()`.
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
    /// A target before the chord's own position within the same measure is
    /// unreachable by a forward-only walk and is dropped rather than
    /// mis-placed.
    func pendingSlurEnds(at position: Fraction) -> [MSCXPendingSlurEnd] {
        runSlurBegins.compactMap { spanner, beginGrace in
            if Self.endsInOwnRun(spanner) { return nil }
            let fractions = spanner.nextFractionsOffset
                ?? Fraction(numerator: 0, denominator: 1)
            let target = position + fractions
            let unreachableInThisMeasure = spanner.nextMeasuresOffset == 0
                && !Self.isStrictlyAfter(target, position)
            if unreachableInThisMeasure { return nil }
            return MSCXPendingSlurEnd(
                measuresAway: spanner.nextMeasuresOffset,
                fraction: target,
                targetGraceIndex: spanner.nextGraceIndex,
                rawType: spanner.rawType,
                prevMeasures: -spanner.nextMeasuresOffset,
                prevFractions: spanner.nextFractionsOffset.map {
                    Fraction(numerator: -$0.numerator, denominator: $0.denominator)
                },
                prevGraceIndex: beginGrace,
            )
        }
    }

    /// `Fraction` is `Hashable` but not `Comparable`; cross-multiplying is
    /// safe because denominators are always positive.
    private static func isStrictlyAfter(_ lhs: Fraction, _ rhs: Fraction) -> Bool {
        lhs.numerator * rhs.denominator > rhs.numerator * lhs.denominator
    }
}

extension GraceChord {
    /// The begin-side `<Spanner>` markers this grace carries — the same form an ordinary chord writes.
    func slurBeginMarkers(options: MSCXEncoderOptions) -> [XMLTreeNode] {
        spanners.map { $0.encodeChordAnchoredBegin(options: options) }
    }
}
