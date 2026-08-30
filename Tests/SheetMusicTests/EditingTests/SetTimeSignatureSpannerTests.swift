@testable import SheetMusicCore
import Testing

/// What a re-bar does to a SPANNER's endpoint — the half of `.setTimeSignature` that is not about notes.
///
/// A spanner never stores where it ends; it stores how far away the end is, in bars of the barring it was
/// written against (`nextMeasuresOffset`) plus a fraction into the bar it lands in (`nextFractionsOffset`).
/// Re-partitioning those bars therefore moves the endpoint unless both halves are restated. Every expectation
/// here is anchored on the one quantity a re-bar must preserve — the ABSOLUTE TICK the endpoint falls on, read
/// back with `endTick(of:anchoredAt:in:)`, which resolves the pair exactly as `HairpinRamps.computeEndTick` and
/// `MSCXEncoder` do.
///
/// Split from `SetTimeSignatureTests` when that suite reached SwiftLint's 400-line type budget.
@Suite("Time signature re-barring — spanner endpoints")
struct SetTimeSignatureSpannerTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    // MARK: - Fixtures

    /// One piano staff, 4 bars of 4/4, a whole-note C in each — 1920 ticks a bar, 7680 in total.
    private func uniform44() -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")])],
            concertKey: 0, measureCount: 4,
        ))
        for measure in 0 ..< 4 {
            let slot = measure == 0 ? 2 : 0
            score.parts[0].staves[0].measures[measure].voices[0].elements[slot] =
                .chord(Chord(duration: .whole, notes: [Note(pitch: 72, tpc: 14)]))
        }
        return score
    }

    /// `uniform44()`'s bars 0–1, then an explicit 3/4 at bar 2 that bars 2–3 fill with a measure rest.
    ///
    /// The point of this one is that a re-bar of bar 1 alone cannot divide evenly: 1920 ticks at 1440 a bar is two
    /// columns, so the region comes out 960 ticks LONGER and bar 2 onward moves later by that much.
    private func changeAtBarTwo() -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")])],
            concertKey: 0, measureCount: 4,
        ))
        for measure in 0 ..< 2 {
            let slot = measure == 0 ? 2 : 0
            score.parts[0].staves[0].measures[measure].voices[0].elements[slot] =
                .chord(Chord(duration: .whole, notes: [Note(pitch: 72, tpc: 14)]))
        }
        score.parts[0].staves[0].measures[2].voices[0].elements
            .insert(.timeSignature(TimeSignature(numerator: 3, denominator: 4)), at: 0)
        return score
    }

    private static func hairpin(measures: Int, fractions: Fraction? = nil) -> VoiceElement {
        .spanner(Spanner(
            kind: .hairpin, rawType: "HairPin",
            nextMeasuresOffset: measures, nextFractionsOffset: fractions,
        ))
    }

    // MARK: - Readers

    /// The first spanner in `measure`, whatever element index it drifted to — a re-bar moves it, and the point of
    /// these tests is that its ENDPOINT survives, not its address.
    private static func spanner(_ score: Score, measure: Int) -> Spanner? {
        for voice in score.parts[0].staves[0].measures[measure].voices {
            for element in voice.elements {
                if case let .spanner(spanner) = element { return spanner }
            }
        }
        return nil
    }

    /// The absolute tick `measureIndex` starts on — what a spanner endpoint really names.
    private static func absoluteStart(of measureIndex: Int, in score: Score) -> Int {
        score.effectiveMeasureDurations().prefix(measureIndex)
            .reduce(0) { $0 + $1.ticks(division: score.division) }
    }

    /// Where a spanner anchored in `measureIndex` says it ends: the start of bar `anchor + measures`, plus
    /// `fractions` into that bar.
    private static func endTick(of spanner: Spanner, anchoredAt measureIndex: Int, in score: Score) -> Int {
        absoluteStart(of: measureIndex + spanner.nextMeasuresOffset, in: score)
            + (spanner.nextFractionsOffset?.ticks(division: score.division) ?? 0)
    }

    private static func measureCount(_ score: Score) -> Int {
        score.parts[0].staves[0].measures.count
    }

    // MARK: - Anchored before the region

    /// A spanner stores a MEASURE distance, so a re-bar that changes how many bars its span covers has to restate
    /// it — otherwise a hairpin drawn to bar 3 silently ends somewhere else.
    @Test("a spanner anchored before the region keeps its endpoint's tick across a re-bar")
    func spannerAcrossRegionKeepsItsEndpoints() {
        var original = uniform44()
        original.parts[0].staves[0].measures[0].voices[0].elements.append(Self.hairpin(measures: 3))
        let endTick = Self.absoluteStart(of: 3, in: original)

        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 2, denominator: 4)))
        // Region [1, 4): 5760 ticks at 960 a bar is six columns, so the score grows 4 bars → 7. The old bar 3
        // started at tick 5760, which is now the head of bar 5 (1920 + 4 x 960).
        #expect(Self.measureCount(session.score) == 7)
        guard let restated = Self.spanner(session.score, measure: 0) else {
            Issue.record("expected the hairpin still in bar 0"); return
        }
        #expect(restated.nextMeasuresOffset == 5)
        #expect(restated.nextFractionsOffset == nil) // the new bar 5 starts exactly on the old end tick
        #expect(Self.endTick(of: restated, anchoredAt: 0, in: session.score) == endTick)
        #expect(session.undo())
        #expect(session.score == original)
        #expect(Self.spanner(session.score, measure: 0)?.nextMeasuresOffset == 3)
    }

    /// The fraction is an offset WITHIN the end bar, so a re-bar has to re-derive it too: an endpoint that fell on
    /// a barline of the old grid can land mid-bar in the new one, and leaving the fraction at `nil` would put the
    /// end back on the nearest new barline instead — here, 960 ticks early.
    @Test("an outside-anchored endpoint landing mid-bar gets its fractions offset re-derived")
    func outsideAnchoredEndpointLandingMidBarGetsAFraction() {
        var original = uniform44()
        original.parts[0].staves[0].measures[0].voices[0].elements.append(Self.hairpin(measures: 3))
        let endTick = Self.absoluteStart(of: 3, in: original)

        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 3, denominator: 4)))
        // Region [1, 4): 5760 ticks at 1440 a bar is four columns, so bars now start at 0, 1920, 3360, 4800,
        // 6240. The old bar 3's tick 5760 falls INSIDE the new bar 3 (4800 ..< 6240), half a bar in.
        #expect(Self.measureCount(session.score) == 5)
        guard let restated = Self.spanner(session.score, measure: 0) else {
            Issue.record("expected the hairpin still in bar 0"); return
        }
        #expect(restated.nextMeasuresOffset == 3)
        #expect(restated.nextFractionsOffset == Fraction(numerator: 1, denominator: 2))
        #expect(Self.endTick(of: restated, anchoredAt: 0, in: session.score) == endTick)
        #expect(session.undo())
        #expect(session.score == original)
        #expect(Self.spanner(session.score, measure: 0)?.nextFractionsOffset == nil)
    }

    // MARK: - Anchored inside the region

    /// The anchor itself moving is the case an outside-anchored-only pass cannot see: `RebarPlanner` carries the
    /// element into whichever new column holds its tick, so the anchor lands right while the offset still counts
    /// bars of the OLD grid — and for a volta that is the span of a repeat ending, which changes what plays.
    @Test("a spanner anchored inside the region has its endpoint restated too")
    func spannerAnchoredInsideRegionIsRestated() {
        var original = uniform44()
        // At the head of bar 1, so its own tick is the bar's — the anchor stays on the new bar 1.
        original.parts[0].staves[0].measures[1].voices[0].elements.insert(Self.hairpin(measures: 2), at: 0)
        let endTick = Self.absoluteStart(of: 3, in: original)

        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 2, denominator: 4)))
        // Region [1, 4) becomes six 960-tick bars starting at 1920; the old bar 3's tick 5760 is the head of the
        // new bar 5, so a hairpin anchored in bar 1 has to say 4 rather than the 2 it still carried.
        #expect(Self.measureCount(session.score) == 7)
        guard let restated = Self.spanner(session.score, measure: 1) else {
            Issue.record("expected the hairpin to land in the new bar 1"); return
        }
        #expect(restated.nextMeasuresOffset == 4)
        #expect(restated.nextFractionsOffset == nil)
        #expect(Self.endTick(of: restated, anchoredAt: 1, in: session.score) == endTick)
        #expect(session.undo())
        #expect(session.score == original)
        #expect(Self.spanner(session.score, measure: 1)?.nextMeasuresOffset == 2)
    }

    /// The same, the other way round: longer bars mean fewer of them, so the offset has to SHRINK — and this one
    /// lands mid-bar, which pins the inside-anchored branch's fraction derivation as well.
    @Test("a spanner anchored inside the region survives a re-bar to longer measures")
    func spannerAnchoredInsideRegionSurvivesAGrow() {
        var original = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")])],
            concertKey: 0, timeNumerator: 3, timeDenominator: 4, measureCount: 4,
        ))
        // After the key and time signature, before the bar's rest, so the anchor's tick is 0.
        original.parts[0].staves[0].measures[0].voices[0].elements.insert(Self.hairpin(measures: 3), at: 2)
        let endTick = Self.absoluteStart(of: 3, in: original)

        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 0, numerator: 4, denominator: 4)))
        // Four 1440-tick bars are 5760 ticks, which at 1920 a bar is three columns starting at 0, 1920, 3840.
        // The old bar 3's tick 4320 falls a quarter into the new bar 2.
        #expect(Self.measureCount(session.score) == 3)
        guard let restated = Self.spanner(session.score, measure: 0) else {
            Issue.record("expected the hairpin still at the head of bar 0"); return
        }
        #expect(restated.nextMeasuresOffset == 2)
        #expect(restated.nextFractionsOffset == Fraction(numerator: 1, denominator: 4))
        #expect(Self.endTick(of: restated, anchoredAt: 0, in: session.score) == endTick)
        #expect(session.undo())
        #expect(session.score == original)
        #expect(Self.spanner(session.score, measure: 0)?.nextMeasuresOffset == 3)
        #expect(Self.spanner(session.score, measure: 0)?.nextFractionsOffset == nil)
    }

    // MARK: - Endpoints past a region that gained length

    /// The case a same-tick lookup gets wrong. `RebarPlanner` fills its last column to nominal length, so a region
    /// whose ticks do not divide by the new bar length comes out LONGER than it went in and pushes every bar after
    /// it later. An endpoint on the far side of that region therefore does NOT keep its old absolute tick — it
    /// keeps its BAR, which has moved. Looking the un-shifted tick up in the new table lands mid-bar, one bar
    /// early.
    ///
    /// Both fixtures here re-bar bar 1 alone from 4/4 to 3/4: 1920 ticks becomes two 1440-tick columns, 960 ticks
    /// of padding, and the explicit 3/4 at bar 2 is what keeps the region that short.
    @Test("an outside-anchored endpoint past a padded region follows the bar it named, not its old tick")
    func outsideAnchoredEndpointPastPaddedRegionFollowsItsBar() {
        var original = changeAtBarTwo()
        original.parts[0].staves[0].measures[0].voices[0].elements.append(Self.hairpin(measures: 2))
        let oldEndBar = 2
        let oldMeasureCount = Self.measureCount(original)

        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 3, denominator: 4)))
        // Bar 1 became two bars, so every bar from 2 on is one further along: the old bar 2 is now bar 3.
        let grew = Self.measureCount(session.score) - oldMeasureCount
        #expect(grew == 1)
        guard let restated = Self.spanner(session.score, measure: 0) else {
            Issue.record("expected the hairpin still in bar 0"); return
        }
        #expect(restated.nextMeasuresOffset == oldEndBar + grew)
        // Still a downbeat: the bar it names moved, it did not slide into the middle of one.
        #expect(restated.nextFractionsOffset == nil)
        #expect(session.undo())
        #expect(session.score == original)
        #expect(Self.spanner(session.score, measure: 0)?.nextMeasuresOffset == 2)
    }

    /// The same defect reached through the inside-anchored path, which shares the one derivation: the anchor is in
    /// the region being padded and the endpoint is past it, so both ends move and only the bar identity survives.
    @Test("an inside-anchored endpoint past a padded region follows the bar it named")
    func insideAnchoredEndpointPastPaddedRegionFollowsItsBar() {
        var original = changeAtBarTwo()
        // At the head of bar 1 — the bar the re-bar splits in two — reaching the downbeat of bar 2.
        original.parts[0].staves[0].measures[1].voices[0].elements.insert(Self.hairpin(measures: 1), at: 0)
        let oldEndBar = 2
        let oldMeasureCount = Self.measureCount(original)

        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 3, denominator: 4)))
        let grew = Self.measureCount(session.score) - oldMeasureCount
        #expect(grew == 1)
        guard let restated = Self.spanner(session.score, measure: 1) else {
            Issue.record("expected the hairpin at the head of the new bar 1"); return
        }
        // Anchored in bar 1 still, and the old bar 2 is now bar 3.
        #expect(1 + restated.nextMeasuresOffset == oldEndBar + grew)
        #expect(restated.nextFractionsOffset == nil)
        #expect(session.undo())
        #expect(session.score == original)
        #expect(Self.spanner(session.score, measure: 1)?.nextMeasuresOffset == 1)
    }

    // MARK: - Left alone

    /// A spanner declaring neither offset carries no endpoint information at all — `MSCXEncoder` writes
    /// `<measures>` only when non-zero and `<fractions>` only when present, so "0 and absent" means it ends
    /// inside its own bar, which stays true however that bar is re-cut. Deriving it from a tick would resolve it
    /// to the start of the anchor's OLD bar and hand back a backwards offset.
    @Test("a spanner with no endpoint offsets at all is left exactly as it is")
    func spannerWithoutOffsetsIsLeftAlone() {
        var original = uniform44()
        // Mid-bar on purpose: after the whole note, so the anchor's tick is a new barline's and a tick-derived
        // endpoint would land in an EARLIER column than the anchor.
        original.parts[0].staves[0].measures[1].voices[0].elements.append(Self.hairpin(measures: 0))

        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 2, denominator: 4)))
        let carried = (0 ..< Self.measureCount(session.score)).compactMap {
            Self.spanner(session.score, measure: $0)
        }
        #expect(carried.count == 1)
        #expect(carried.first?.nextMeasuresOffset == 0)
        #expect(carried.first?.nextFractionsOffset == nil)
        #expect(session.undo())
        #expect(session.score == original)
    }

    /// "No endpoint" is not always spelled as an absent fraction. `MSCXDecoder+Spanner` builds a `Fraction` from
    /// whatever `<fractions>` node it finds, so a file writing `0/1` decodes to a non-nil fraction worth no ticks
    /// — the same nothing, in a spelling a `!= nil` test waves through. Here the anchor is on a bar head, so the
    /// derivation would come back with a perfectly plausible offset 0 and rewrite the element to say `nil`;
    /// elsewhere in the bar the very same input yields a negative offset.
    @Test("a zero-valued fractions offset counts as no endpoint, like an absent one")
    func spannerWithZeroFractionIsLeftAlone() {
        var original = uniform44()
        original.parts[0].staves[0].measures[1].voices[0].elements.insert(
            Self.hairpin(measures: 0, fractions: Fraction(numerator: 0, denominator: 1)), at: 0,
        )

        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 2, denominator: 4)))
        guard let carried = Self.spanner(session.score, measure: 1) else {
            Issue.record("expected the hairpin at the head of the new bar 1"); return
        }
        #expect(carried.nextMeasuresOffset == 0)
        #expect(carried.nextFractionsOffset == Fraction(numerator: 0, denominator: 1))
        #expect(session.undo())
        #expect(session.score == original)
    }
}
