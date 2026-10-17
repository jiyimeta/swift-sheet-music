@testable import SheetMusicCore
import Testing

/// What `FormatRhythms` must leave alone (markings it could not carry over) and how it reads a score's bars: each
/// protection test pairs the protected input with a control that DOES change, so a pass cannot mean "nothing ever
/// changes".
@Suite("FormatRhythms protection and bars")
struct FormatRhythmsProtectionTests {
    private typealias Base = FormatRhythmsTests
    private typealias Bars = FormatRhythmsBarPlannerTests

    private static func plan(_ score: Score, scope: FormatRhythmsScope = .score) throws -> CompositeEditCommand? {
        var identified = score
        var ids = EIDAllocator()
        identified.assignMissingIDs(using: &ids)
        return try FormatRhythms(scope: scope, policy: Base.policy).plan(in: identified, ids: ids)
    }

    private static func slur(measures: Int, quarters: Int) -> Spanner {
        Spanner(
            kind: .slur, rawType: "Slur", nextMeasuresOffset: measures,
            nextFractionsOffset: Fraction(numerator: quarters, denominator: 4),
        )
    }

    /// A whole note whose slur ends `quarters` quarter notes after its own start (`measures` bars on).
    private static func slurredWhole(measures: Int, quarters: Int) -> VoiceElement {
        var chord = Bars.chord(1, 1)
        chord.spanners = [slur(measures: measures, quarters: quarters)]
        return .chord(chord)
    }

    // MARK: Lyrics

    private static func melismaBar(ticks: Int) -> Measure {
        var head = Bars.chord(1, 4, tieForward: true)
        head.lyrics = [Lyric(text: "la", ticks: ticks)]
        return Base.bar([.chord(head), Bars.note(1, 4, tieBack: true), Bars.rest(1, 2)])
    }

    @Test("a melisma target on the continuation stops the merge; a target elsewhere does not")
    func melismaTarget() throws {
        // The melisma runs one quarter (480 ticks): its target is the tied continuation's onset.
        #expect(try Self.plan(Base.score([[Self.melismaBar(ticks: 480)]])) == nil)
        // Control: a target at the half rest's onset (960) leaves the chain free to merge.
        #expect(try Self.plan(Base.score([[Self.melismaBar(ticks: 960)]])) != nil)
    }

    // MARK: Slurs

    @Test("a slur ending in a LATER bar protects the continuation there (the tick rolls across the bar line)")
    func slurEndsInLaterBar() throws {
        // Start at tick 0 of bar 0; five quarters on is bar 1, tick 480 — the second tied quarter.
        let chain = Base.bar(Base.tiedPair())
        let slurred = Base.bar([Self.slurredWhole(measures: 0, quarters: 5)])
        #expect(try Self.plan(Base.score([[slurred, chain]])) == nil)
        // The same end written as one bar on plus one quarter.
        let viaOffset = Base.bar([Self.slurredWhole(measures: 1, quarters: 1)])
        #expect(try Self.plan(Base.score([[viaOffset, chain]])) == nil)
        // Control: without the slur bar 1 formats.
        #expect(try Self.plan(Base.score([[Base.bar([Bars.note(1, 1)]), chain]])) != nil)
    }

    @Test("a slur in voice 0 protects a chain in voice 1 of the same staff-bar")
    func slurProtectsOtherVoice() throws {
        let slurred = [Self.slurredWhole(measures: 0, quarters: 1)]
        #expect(try Self.plan(Base.score([[Base.bar(slurred, Base.tiedPair())]])) == nil)
        // Control: voice 0 without the slur lets voice 1's chain merge.
        let plain: [VoiceElement] = [Bars.note(1, 1)]
        #expect(try Self.plan(Base.score([[Base.bar(plain, Base.tiedPair())]])) != nil)
    }

    // MARK: Scope

    @Test("a range across two bars and two staves formats exactly those bars of those staves")
    func rangeAcrossBarsAndStaves() throws {
        let staff = [Base.bar(Base.tiedPair()), Base.bar(Base.tiedPair()), Base.bar(Base.tiedPair())]
        var score = Base.score([staff, staff, staff])
        let before = score
        let range = VoiceElementRange(
            start: Base.slot(Base.staff0, measure: 1, element: 0),
            end: Base.slot(Base.staff1, measure: 2, element: 1),
        )
        _ = try FormatRhythms(scope: .range(range), policy: Base.policy).apply(to: &score)
        for address in [Base.staff0, Base.staff1] {
            #expect(Base.durations(score, address, measure: 1) == [Base.half, Base.half])
            #expect(Base.durations(score, address, measure: 2) == [Base.half, Base.half])
            #expect(Base.durations(score, address, measure: 0) == Base.durations(before, address, measure: 0))
        }
        let untouched = StaffAddress(partIndex: 0, staffIndexInPart: 2)
        for measure in 0 ... 2 {
            let after = Base.durations(score, untouched, measure: measure)
            #expect(after == Base.durations(before, untouched, measure: measure))
        }
    }

    // MARK: Bars

    @Test("a short bar is a pickup when it is irregular or follows a section break, not otherwise")
    func pickupRecognition() throws {
        /// 5/8 holding one note: right-aligned (a pickup) it is an eighth tied to a half; left-aligned, a half tied to
        /// an eighth.
        func shortBar(irregular: Bool = false) -> Measure {
            Measure(
                voices: [Voice(elements: [Bars.note(5, 8)])],
                actualLength: Fraction(numerator: 5, denominator: 8), irregular: irregular,
            )
        }
        let full = Base.bar([Bars.note(1, 1)])
        let rightAligned = [Bars.duration(1, 8), Bars.duration(1, 2)]
        let leftAligned = [Bars.duration(1, 2), Bars.duration(1, 8)]

        func formatted(_ bars: [Measure]) throws -> [NoteDuration] {
            var score = Base.score([bars])
            _ = try FormatRhythms(scope: .score, policy: Base.policy).apply(to: &score)
            return Base.durations(score, measure: 1)
        }
        #expect(try formatted([full, shortBar()]) == leftAligned)
        #expect(try formatted([full, shortBar(irregular: true)]) == rightAligned)
        let sectionEnd = Measure(voices: [Voice(elements: [Bars.note(1, 1)])], sectionBreak: true)
        #expect(try formatted([sectionEnd, shortBar()]) == rightAligned)
    }

    @Test("a meter change mid-score spells each bar by its own meter")
    func meterChange() throws {
        let four = VoiceElement.timeSignature(TimeSignature(numerator: 4, denominator: 4))
        let six = VoiceElement.timeSignature(TimeSignature(numerator: 6, denominator: 8))
        /// Eighth, eighth, quarter, quarter: the FIRST quarter starts at 1/4 — on a beat in 4/4, and across the
        /// dotted-beat boundary at 3/8 in 6/8.
        func body(_ meter: VoiceElement, rest: Bool) -> Measure {
            var elements: [VoiceElement] = [
                meter, Bars.note(1, 8), Bars.note(1, 8), Bars.note(1, 4, pitch: 62), Bars.note(1, 4, pitch: 64),
            ]
            if rest { elements.append(Bars.rest(1, 4)) }
            return Measure(voices: [Voice(elements: elements)])
        }
        var score = Base.score([[body(four, rest: true), body(six, rest: false)]])
        let before = score
        _ = try FormatRhythms(scope: .score, policy: Base.policy).apply(to: &score)
        #expect(Base.durations(score, measure: 0) == Base.durations(before, measure: 0))
        let eighth = Bars.duration(1, 8)
        #expect(Base.durations(score, measure: 1).prefix(4) == [eighth, eighth, eighth, eighth])
        // Control: the same figure completed to a full 4/4 bar, twice over, has nothing to change.
        let asFour = Base.score([[body(four, rest: true), body(four, rest: true)]])
        #expect(try Self.plan(asFour) == nil)
    }

    // MARK: Malformed offsets

    /// A two-bar staff whose SECOND bar starts with a whole note carrying `spanner` — so `1 + Int.max` would trap
    /// without the offset clamp — followed by nothing else.
    private static func collected(slur spanner: Spanner) -> [FormatRhythmsProtectedOnsets.Bar: Set<Int>] {
        var chord = Bars.chord(1, 1)
        chord.spanners = [spanner]
        return FormatRhythmsProtectedOnsets.collect(
            in: Base.score([[Base.bar(Base.tiedPair()), Base.bar([.chord(chord)])]]),
        )
    }

    @Test("a slur with a huge bar offset in a later bar collects without trapping")
    func hugeBarOffset() {
        for fraction in [-3, 0, 1] {
            let spanner = Spanner(
                kind: .slur, rawType: "Slur", nextMeasuresOffset: Int.max,
                nextFractionsOffset: Fraction(numerator: fraction, denominator: 1),
            )
            #expect(Self.collected(slur: spanner).isEmpty)
        }
    }

    @Test("a slur whose bar offset is in range but whose fraction runs before the staff collects nothing")
    func negativeFraction() {
        // Start at bar 1 tick 0, offset 0, three whole notes back: before bar 0.
        let spanner = Spanner(
            kind: .slur, rawType: "Slur", nextMeasuresOffset: 0,
            nextFractionsOffset: Fraction(numerator: -3, denominator: 1),
        )
        #expect(Self.collected(slur: spanner).isEmpty)
        // Control: one quarter forward lands inside the staff.
        let forward = Spanner(
            kind: .slur, rawType: "Slur", nextMeasuresOffset: 0,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
        )
        #expect(Self.collected(slur: forward).values.contains([480]))
    }

    @Test("a lyric melisma length that overflows the tick sum collects nothing instead of trapping")
    func hugeMelisma() {
        var head = Bars.chord(1, 2)
        head.lyrics = [Lyric(text: "la", ticks: Int.max)]
        let score = Base.score([[Base.bar([Bars.note(1, 2), .chord(head)])]])
        #expect(FormatRhythmsProtectedOnsets.collect(in: score).isEmpty)
    }
}
