@testable import SheetMusicCore
import Testing

/// The half of the re-bar's spanner restatement that is not a `.spanner` VOICE ELEMENT.
///
/// A slur's begin side does not get an element of its own: it rides in `Chord.spanners` on the chord it starts
/// on (`SpannerPlacement` — MuseScore writes it inside the `<Chord>`). Its `nextMeasuresOffset` is measured from
/// exactly the same anchor as an element-shaped spanner's, so a re-bar moves it in exactly the same way — but
/// `SetTimeSignature+Spanners`' three walks saw only `.spanner` elements, and a chord-anchored slur therefore
/// came out of a re-bar still counting bars of the OLD barring.
///
/// `MeasureStructure.adjustSpannerOffsets` was taught both shapes when `InsertMeasure` / `DeleteMeasure` needed
/// it (`SpannerOffsetsTests.slurFollowsAMeasureInsertion`); this suite is the same defect reached through
/// `.setTimeSignature`, whose re-bar path is the other writer of those offsets.
///
/// Every expectation is anchored on the ABSOLUTE TICK the endpoint falls on, the way
/// `SetTimeSignatureSpannerTests` does — the pair is only a spelling of that tick under the current barring.
@Suite("Time signature re-barring — chord-anchored spanner endpoints")
struct SetTimeSignatureChordSpannerTests {
    // MARK: - Fixtures

    /// One piano staff, 4 bars of 4/4, a whole-note C in each — 1920 ticks a bar, 7680 in total. The same shape
    /// `SetTimeSignatureSpannerTests` uses, so the chord-anchored expectations can be read against the
    /// element-anchored ones bar for bar.
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

    private static func slur(measures: Int, fractions: Fraction? = nil) -> Spanner {
        Spanner(
            kind: .slur, rawType: "Slur",
            nextMeasuresOffset: measures, nextFractionsOffset: fractions,
        )
    }

    private static func hairpin(measures: Int) -> VoiceElement {
        .spanner(Spanner(kind: .hairpin, rawType: "HairPin", nextMeasuresOffset: measures))
    }

    /// Hangs `spanners` off the first chord of `measure`, which is where a slur begin lives.
    private static func attach(_ spanners: [Spanner], toChordIn measure: Int, of score: inout Score) {
        for voiceIndex in score.parts[0].staves[0].measures[measure].voices.indices {
            let elements = score.parts[0].staves[0].measures[measure].voices[voiceIndex].elements
            for index in elements.indices {
                guard case var .chord(chord) = elements[index] else { continue }
                chord.spanners = spanners
                score.parts[0].staves[0].measures[measure].voices[voiceIndex].elements[index] = .chord(chord)
                return
            }
        }
        Issue.record("no chord in bar \(measure) to anchor a slur on")
    }

    // MARK: - Readers

    /// The spanners of the first chord in `measure` that carries any — a re-bar moves the chord's address and
    /// may split it into a tied chain, and the point of these tests is that the ENDPOINT survives, not the
    /// address.
    private static func chordSpanners(_ score: Score, measure: Int) -> [Spanner] {
        for voice in score.parts[0].staves[0].measures[measure].voices {
            for element in voice.elements {
                if case let .chord(chord) = element, !chord.spanners.isEmpty { return chord.spanners }
            }
        }
        return []
    }

    private static func elementSpanner(_ score: Score, measure: Int) -> Spanner? {
        for voice in score.parts[0].staves[0].measures[measure].voices {
            for element in voice.elements {
                if case let .spanner(spanner) = element { return spanner }
            }
        }
        return nil
    }

    private static func absoluteStart(of measureIndex: Int, in score: Score) -> Int {
        score.effectiveMeasureDurations().prefix(measureIndex)
            .reduce(0) { $0 + $1.ticks(division: score.division) }
    }

    private static func endTick(of spanner: Spanner, anchoredAt measureIndex: Int, in score: Score) -> Int {
        absoluteStart(of: measureIndex + spanner.nextMeasuresOffset, in: score)
            + (spanner.nextFractionsOffset?.ticks(division: score.division) ?? 0)
    }

    private static func measureCount(_ score: Score) -> Int {
        score.parts[0].staves[0].measures.count
    }

    // MARK: - Anchored before the region

    /// The reported defect. The slur's chord sits in bar 0, which the re-bar never touches, so nothing about the
    /// anchor changes — only how many bars lie between it and the moment it reaches.
    @Test("a chord-anchored slur before the region keeps its endpoint's tick across a re-bar")
    func slurBeforeRegionKeepsItsEndpointTick() {
        var original = uniform44()
        Self.attach([Self.slur(measures: 3)], toChordIn: 0, of: &original)
        let endTick = Self.absoluteStart(of: 3, in: original)

        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 2, denominator: 4)))
        // Region [1, 4): 5760 ticks at 960 a bar is six columns, so the score grows to 7 bars. The old bar 3
        // started at tick 5760, which is now the head of bar 5 (1920 + 4 x 960).
        #expect(Self.measureCount(session.score) == 7)
        let restated = Self.chordSpanners(session.score, measure: 0)
        #expect(restated.count == 1)
        guard let slur = restated.first else { return }
        #expect(slur.nextMeasuresOffset == 5)
        #expect(slur.nextFractionsOffset == nil)
        #expect(Self.endTick(of: slur, anchoredAt: 0, in: session.score) == endTick)
        #expect(session.undo())
        #expect(session.score == original)
        #expect(Self.chordSpanners(session.score, measure: 0).first?.nextMeasuresOffset == 3)
    }

    /// The fraction half, on the chord-anchored shape: an endpoint on an old barline can land mid-bar in the new
    /// grid, and leaving `nextFractionsOffset` at `nil` would pull the slur back to the nearest new barline.
    @Test("a chord-anchored slur landing mid-bar gets its fractions offset re-derived")
    func slurBeforeRegionLandingMidBarGetsAFraction() {
        var original = uniform44()
        Self.attach([Self.slur(measures: 3)], toChordIn: 0, of: &original)
        let endTick = Self.absoluteStart(of: 3, in: original)

        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 3, denominator: 4)))
        // Bars now start at 0, 1920, 3360, 4800, 6240; the old bar 3's tick 5760 falls half a bar into bar 3.
        #expect(Self.measureCount(session.score) == 5)
        guard let slur = Self.chordSpanners(session.score, measure: 0).first else {
            Issue.record("expected the slurred chord still in bar 0"); return
        }
        #expect(slur.nextMeasuresOffset == 3)
        #expect(slur.nextFractionsOffset == Fraction(numerator: 1, denominator: 2))
        #expect(Self.endTick(of: slur, anchoredAt: 0, in: session.score) == endTick)
        #expect(session.undo())
        #expect(session.score == original)
    }

    // MARK: - Anchored inside the region

    /// The anchor moves too: `RebarPlanner` carries the chord into whichever new column holds its tick (and
    /// splits it into a tied chain, of which only the HEAD keeps `spanners`), so the offset has to be re-derived
    /// against the anchor's new bar rather than its old one.
    @Test("a chord-anchored slur inside the region has its endpoint restated too")
    func slurInsideRegionIsRestated() {
        var original = uniform44()
        Self.attach([Self.slur(measures: 2)], toChordIn: 1, of: &original)
        let endTick = Self.absoluteStart(of: 3, in: original)

        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 2, denominator: 4)))
        #expect(Self.measureCount(session.score) == 7)
        // The whole note became a tied chain; only its head carries the slur, and that head is the new bar 1.
        guard let slur = Self.chordSpanners(session.score, measure: 1).first else {
            Issue.record("expected the slurred chord to land in the new bar 1"); return
        }
        #expect(slur.nextMeasuresOffset == 4)
        #expect(slur.nextFractionsOffset == nil)
        #expect(Self.endTick(of: slur, anchoredAt: 1, in: session.score) == endTick)
        #expect(session.undo())
        #expect(session.score == original)
        #expect(Self.chordSpanners(session.score, measure: 1).first?.nextMeasuresOffset == 2)
    }

    // MARK: - Per-slot addressing

    /// A chord can carry several entries — an inner and an outer slur — each declaring its OWN endpoint. The
    /// slot has to travel with the address or the wrong entry gets written, which is why
    /// `MeasureStructure.SpannerAddress` carries one too.
    ///
    /// Both slots here declare an endpoint (offsets 3 and 2) so the test pins that each one lands in ITS OWN
    /// slot rather than merely proving "some slot gets written" — the shape a `setOffsets` that always wrote
    /// `chord.spanners[0]` would still pass if only one slot declared anything (the previous version of this
    /// test used offset 0 / no fraction for the second slur, which `remapped` treats as "nothing to restate"
    /// and therefore never reaches `setOffsets` at all).
    @Test("each slot that declares an endpoint is restated to its OWN slot")
    func onlyTheDeclaringSlotIsRestated() {
        var original = uniform44()
        Self.attach([Self.slur(measures: 3), Self.slur(measures: 2)], toChordIn: 0, of: &original)

        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 2, denominator: 4)))
        let restated = Self.chordSpanners(session.score, measure: 0)
        #expect(restated.count == 2)
        #expect(restated.first?.nextMeasuresOffset == 5)
        #expect(restated.first?.nextFractionsOffset == nil)
        #expect(restated.last?.nextMeasuresOffset == 3)
        #expect(restated.last?.nextFractionsOffset == nil)
        #expect(session.undo())
        #expect(session.score == original)
        #expect(Self.chordSpanners(session.score, measure: 0).first?.nextMeasuresOffset == 3)
        #expect(Self.chordSpanners(session.score, measure: 0).last?.nextMeasuresOffset == 2)
    }

    // MARK: - The shape that must not change

    /// The regression guard for the fix itself: an element-shaped spanner across the very same re-bar keeps
    /// answering exactly as it did before the walks learned about chords, and the two shapes do not interfere —
    /// each is restated against its own anchor.
    @Test("an element-shaped spanner across the same re-bar is unaffected by the chord walk")
    func elementShapedSpannerStillWorksAlongsideAChordAnchoredOne() {
        var original = uniform44()
        Self.attach([Self.slur(measures: 3)], toChordIn: 0, of: &original)
        original.parts[0].staves[0].measures[0].voices[0].elements.append(Self.hairpin(measures: 3))
        let endTick = Self.absoluteStart(of: 3, in: original)

        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 2, denominator: 4)))
        guard let hairpin = Self.elementSpanner(session.score, measure: 0) else {
            Issue.record("expected the hairpin still in bar 0"); return
        }
        #expect(hairpin.nextMeasuresOffset == 5)
        #expect(hairpin.nextFractionsOffset == nil)
        #expect(Self.endTick(of: hairpin, anchoredAt: 0, in: session.score) == endTick)
        #expect(Self.chordSpanners(session.score, measure: 0).first?.nextMeasuresOffset == 5)
        #expect(session.undo())
        #expect(session.score == original)
        #expect(Self.elementSpanner(session.score, measure: 0)?.nextMeasuresOffset == 3)
    }
}
