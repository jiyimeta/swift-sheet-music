@testable import SheetMusicCore
import Testing

/// What a duplicated range does with SPANNERS, in both directions.
///
/// MuseScore's copy is all-or-nothing: a slur is written per ChordRest (`twrite.cpp:1132-1151`) and one crossing
/// an edge is written dangling and then dropped when the connector cannot be paired; a hairpin-class spanner is
/// written only when both ends are inside the selection (`twrite.cpp:3560-3571`). Its paste opens the gap with
/// `makeGap1` → `deleteOrShortenOutSpannersFromRange` (`cmd.cpp:1505`, `edit.cpp:3638-3702`), which removes a
/// spanner fully inside the gap, removes a SLUR that touches it (`3686-3688`), and SHORTENS a hairpin-class
/// spanner out of it (`3689-3700`).
@Suite("DuplicateRange spanners")
struct RangeCopySpannersTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func voice(_ score: Score, _ measure: Int) -> Voice {
        score.parts[0].staves[0].measures[measure].voices[0]
    }

    private static func quarter(_ pitch: Int, _ tpc: Int, spanners: [Spanner] = []) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)], spanners: spanners))
    }

    private static func score(_ measures: [Measure]) -> Score {
        Score(division: 480, parts: [
            Part(
                id: "1", trackName: "Flute", instrument: Instrument(id: "flute"),
                staves: [Staff(defaultClefType: "G", measures: measures)],
            ),
        ])
    }

    private static func slur(measures: Int, fractions: Fraction?) -> Spanner {
        Spanner(
            kind: .slur, rawType: "Slur", nextMeasuresOffset: measures, nextFractionsOffset: fractions,
        )
    }

    private static func hairpin(measures: Int, fractions: Fraction?) -> Spanner {
        Spanner(
            kind: .hairpin, rawType: "HairPin", nextMeasuresOffset: measures, nextFractionsOffset: fractions,
            hairpin: Spanner.HairpinPayload(subtype: .crescendo),
        )
    }

    /// A pedal: a line spanner MuseScore's gap pass does NOT collect, so nothing here may remove or clip it.
    private static func pedal(measures: Int, fractions: Fraction?) -> Spanner {
        Spanner(
            kind: .pedal, rawType: "Pedal", nextMeasuresOffset: measures, nextFractionsOffset: fractions,
        )
    }

    /// The spanners the chord at `index` of `measure`'s voice 0 carries.
    private static func chordSpanners(_ score: Score, _ measure: Int, _ index: Int) -> [Spanner] {
        guard case let .chord(chord) = voice(score, measure).elements[index] else { return [] }
        return chord.spanners
    }

    /// Every `.spanner` element standing in `measure`'s voice 0, in voice order.
    private static func lineSpanners(_ score: Score, _ measure: Int) -> [Spanner] {
        voice(score, measure).elements.values.compactMap {
            guard case let .spanner(spanner) = $0 else { return nil }
            return spanner
        }
    }

    private static let quarterRestBar = Measure(voices: [Voice(elements: [
        .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
    ])])

    // MARK: - Copy side

    @Test("a slur lying entirely inside the range travels with the copy, re-anchored on the copy's own chords")
    func copiesAnEnclosedSlur() throws {
        var score = Self.score([
            Measure(voices: [Voice(elements: [
                Self.quarter(60, 14, spanners: [
                    Self.slur(measures: 0, fractions: Fraction(ticks: 960, division: 480)),
                ]),
                Self.quarter(62, 16), Self.quarter(64, 18), Self.quarter(65, 19),
            ])]),
            Self.quarterRestBar,
        ])
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 3)))
            .apply(to: &score)
        let copied = Self.chordSpanners(score, 1, 0)
        #expect(copied.count == 1)
        // Beat 1 to beat 3 of the copy's own bar: the same two-beat arc, spelled against the destination.
        #expect(copied.first?.kind == .slur)
        #expect(copied.first?.nextMeasuresOffset == 0)
        #expect(copied.first?.nextFractionsOffset == Fraction(ticks: 960, division: 480))
    }

    @Test("a slur that ends past the range's end is not copied")
    func dropsASlurCrossingTheRangeEnd() throws {
        var score = Self.score([
            Measure(voices: [Voice(elements: [
                Self.quarter(60, 14, spanners: [Self.slur(measures: 1, fractions: nil)]),
                Self.quarter(62, 16), Self.quarter(64, 18), Self.quarter(65, 19),
            ])]),
            Self.quarterRestBar,
        ])
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 3)))
            .apply(to: &score)
        // Its end chord is the downbeat of the bar AFTER the range, so MuseScore's connector never pairs.
        #expect(Self.chordSpanners(score, 1, 0).isEmpty)
    }

    @Test("a hairpin with both ends inside the range travels with the copy")
    func copiesAnEnclosedHairpin() throws {
        var score = Self.score([
            Measure(voices: [Voice(elements: [
                .spanner(Self.hairpin(measures: 0, fractions: Fraction(ticks: 960, division: 480))),
                Self.quarter(60, 14), Self.quarter(62, 16), Self.quarter(64, 18), Self.quarter(65, 19),
            ])]),
            Self.quarterRestBar,
        ])
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)))
            .apply(to: &score)
        let copied = Self.lineSpanners(score, 1)
        #expect(copied.count == 1)
        #expect(copied.first?.kind == .hairpin)
        #expect(copied.first?.hairpin?.subtype == .crescendo)
        #expect(copied.first?.nextMeasuresOffset == 0)
        #expect(copied.first?.nextFractionsOffset == Fraction(ticks: 960, division: 480))
        // It stands immediately before the copy's first chord, the placement every line spanner uses.
        guard case .spanner = Self.voice(score, 1).elements[0] else {
            Issue.record("expected the hairpin ahead of the copied chords")
            return
        }
    }

    @Test("a hairpin that ends past the range's end is not copied")
    func dropsAHairpinCrossingTheRangeEnd() throws {
        var score = Self.score([
            Measure(voices: [Voice(elements: [
                .spanner(Self.hairpin(measures: 1, fractions: Fraction(ticks: 480, division: 480))),
                Self.quarter(60, 14), Self.quarter(62, 16), Self.quarter(64, 18), Self.quarter(65, 19),
            ])]),
            // Three bars, not two: the copy's own far end has to land somewhere the staff HAS, or the drop
            // would be the out-of-score guard in `recreate` rather than the all-or-nothing rule under test.
            Self.quarterRestBar,
            Self.quarterRestBar,
        ])
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)))
            .apply(to: &score)
        // All-or-nothing (`twrite.cpp:3560-3571`): one end outside the selection means the whole line stays home.
        #expect(Self.lineSpanners(score, 1).isEmpty)
    }

    // MARK: - Destination side

    @Test("a destination slur reaching into the copy's span is removed outright")
    func removesADestinationSlurTouchingTheSpan() throws {
        var score = Self.score([
            Measure(voices: [Voice(elements: [
                Self.quarter(60, 14, spanners: [
                    Self.slur(measures: 0, fractions: Fraction(ticks: 1440, division: 480)),
                ]),
                Self.quarter(62, 16), Self.quarter(64, 18), Self.quarter(65, 19),
            ])]),
        ])
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 1)))
            .apply(to: &score)
        // The copy lands on beats 3 and 4; the slur ran from beat 1 into beat 4, so `edit.cpp:3686-3688` drops it.
        #expect(Self.chordSpanners(score, 0, 0).isEmpty)
        #expect(Self.voice(score, 0).elements.count == 4)
    }

    @Test("a destination hairpin reaching into the copy's span is shortened out of it, not removed")
    func shortensADestinationHairpinIntoTheSpan() throws {
        var score = Self.score([
            Measure(voices: [Voice(elements: [
                .spanner(Self.hairpin(measures: 0, fractions: Fraction(ticks: 1440, division: 480))),
                Self.quarter(60, 14), Self.quarter(62, 16), Self.quarter(64, 18), Self.quarter(65, 19),
            ])]),
        ])
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2)))
            .apply(to: &score)
        let remaining = Self.lineSpanners(score, 0)
        #expect(remaining.count == 1)
        // It still starts on beat 1 and now stops where the copy begins, on beat 3 (`edit.cpp:3689-3700`).
        #expect(remaining.first?.nextMeasuresOffset == 0)
        #expect(remaining.first?.nextFractionsOffset == Fraction(ticks: 960, division: 480))
    }

    // MARK: - Destination side: the bounds at both ends of the gap

    /// Four bars: the first carries the material and the spanner under test, and the copy of bar 0 lands on
    /// bar 1. A spanner ending in bar 3 therefore arches clean over the copy's span with neither endpoint in it.
    private static func fourBars(opening elements: [VoiceElement]) -> Score {
        score([
            Measure(voices: [Voice(elements: elements)]),
            quarterRestBar, quarterRestBar, quarterRestBar,
        ])
    }

    @Test("a destination slur that arches over the whole copy is left alone")
    func keepsASlurSpanningTheWholeSpan() throws {
        var score = Self.fourBars(opening: [
            Self.quarter(60, 14, spanners: [Self.slur(measures: 3, fractions: nil)]),
            Self.quarter(62, 16), Self.quarter(64, 18), Self.quarter(65, 19),
        ])
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 3)))
            .apply(to: &score)
        // MuseScore's removal test is `tick2 >= t1 && tick2 < t2`; this arc's end chord is past `t2`, so nothing
        // it touches is being overwritten and it keeps the offsets it had.
        let kept = Self.chordSpanners(score, 0, 0)
        #expect(kept.count == 1)
        #expect(kept.first?.nextMeasuresOffset == 3)
        #expect(kept.first?.nextFractionsOffset == nil)
    }

    @Test("a destination hairpin that arches over the whole copy is left alone")
    func keepsAHairpinSpanningTheWholeSpan() throws {
        var score = Self.fourBars(opening: [
            .spanner(Self.hairpin(measures: 3, fractions: nil)),
            Self.quarter(60, 14), Self.quarter(62, 16), Self.quarter(64, 18), Self.quarter(65, 19),
        ])
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)))
            .apply(to: &score)
        // `moveEnd`'s test is `tick2 > t1 && tick2 <= t2`; this one ends past `t2`, so it is not shortened.
        let kept = Self.lineSpanners(score, 0)
        #expect(kept.count == 1)
        #expect(kept.first?.nextMeasuresOffset == 3)
        #expect(kept.first?.nextFractionsOffset == nil)
    }

    @Test("a destination slur whose end chord is the copy's first is removed")
    func removesASlurEndingOnTheSpanStart() throws {
        var score = Self.score([
            Measure(voices: [Voice(elements: [
                Self.quarter(60, 14, spanners: [
                    Self.slur(measures: 0, fractions: Fraction(ticks: 960, division: 480)),
                ]),
                Self.quarter(62, 16), Self.quarter(64, 18), Self.quarter(65, 19),
            ])]),
        ])
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 1)))
            .apply(to: &score)
        // The arc ended on beat 3, which is the first chord the copy overwrites — the closed lower bound of
        // MuseScore's `tick2 >= t1` is exactly this case.
        #expect(Self.chordSpanners(score, 0, 0).isEmpty)
    }

    // MARK: - Destination side: the kinds the gap pass does not collect

    @Test("a destination pedal reaching into the copy's span is not shortened")
    func leavesAPedalReachingIntoTheSpan() throws {
        var score = Self.score([
            Measure(voices: [Voice(elements: [
                .spanner(Self.pedal(measures: 0, fractions: Fraction(ticks: 1440, division: 480))),
                Self.quarter(60, 14), Self.quarter(62, 16), Self.quarter(64, 18), Self.quarter(65, 19),
            ])]),
        ])
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2)))
            .apply(to: &score)
        // `deleteOrShortenOutSpannersFromRange` collects hairpin, ottava, trill and vibrato and no other kind
        // (`edit.cpp:3641-3646`), so a pedal in the same position as the shortened hairpin above keeps its end.
        let kept = Self.lineSpanners(score, 0)
        #expect(kept.count == 1)
        #expect(kept.first?.kind == .pedal)
        #expect(kept.first?.nextFractionsOffset == Fraction(ticks: 1440, division: 480))
    }

    @Test("a destination pedal lying wholly inside the copy's span is removed with the material under it")
    func removesAPedalInsideTheSpan() throws {
        var score = Self.score([
            Measure(voices: [Voice(elements: [
                Self.quarter(60, 14), Self.quarter(62, 16),
                .spanner(Self.pedal(measures: 0, fractions: Fraction(ticks: 960, division: 480))),
                Self.quarter(64, 18), Self.quarter(65, 19),
            ])]),
        ])
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 1)))
            .apply(to: &score)
        // The copy lands on beats 3 and 4, which is where the pedal starts and where it ends. MuseScore's
        // wholly-inside branch is kind-agnostic — `undoRemoveElement(sp)` for any spanner whose start is in
        // `[t1, t2)` and whose end is in `(t1, t2]` (`edit.cpp:3683-3685`), with only a volta and a
        // system-flagged spanner skipped ahead of it (`:3659`). The four-kind set gates the SHORTEN branches
        // below it (`:3690-3698`), not this one, so a pedal buried in the gap goes the way a hairpin does.
        #expect(Self.lineSpanners(score, 0).isEmpty)
    }

    @Test("a destination pedal anchored inside the copy's span but reaching past it survives")
    func leavesAPedalReachingOutOfTheSpan() throws {
        var score = Self.score([
            Measure(voices: [Voice(elements: [
                Self.quarter(60, 14), Self.quarter(62, 16),
                .spanner(Self.pedal(measures: 1, fractions: nil)),
                Self.quarter(64, 18), Self.quarter(65, 19),
            ])]),
            Self.quarterRestBar,
        ])
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 1)))
            .apply(to: &score)
        // Anchored at beat 3 — inside the span — but ending in the next bar, so it is neither wholly inside
        // the gap nor one of the four kinds `moveStart` shortens: MuseScore's pass leaves it entirely alone,
        // and it stays at its own tick among the new material.
        let kept = Self.lineSpanners(score, 0)
        #expect(kept.count == 1)
        #expect(kept.first?.kind == .pedal)
    }

    // MARK: - Destination side: the start-side shorten

    @Test("a destination hairpin the copy's span starts inside is restarted at the span's far edge")
    func restartsAHairpinWhoseStartTheSpanSwallowed() throws {
        var score = Self.score([
            Measure(voices: [Voice(elements: [
                Self.quarter(60, 14), Self.quarter(62, 16),
                .spanner(Self.hairpin(measures: 1, fractions: nil)),
                Self.quarter(64, 18), Self.quarter(65, 19),
            ])]),
            Self.quarterRestBar,
        ])
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 1)))
            .apply(to: &score)
        // It began on beat 3 of bar 0, which the copy takes, and ended on beat 3 of bar 1, which the copy does
        // not reach. MuseScore's `moveStart` re-homes it to the gap's far edge rather than deleting it.
        #expect(Self.lineSpanners(score, 0).isEmpty)
        let moved = Self.lineSpanners(score, 1)
        #expect(moved.count == 1)
        #expect(moved.first?.kind == .hairpin)
        #expect(moved.first?.nextMeasuresOffset == 0)
        #expect(moved.first?.nextFractionsOffset == Fraction(ticks: 960, division: 480))
    }
}
