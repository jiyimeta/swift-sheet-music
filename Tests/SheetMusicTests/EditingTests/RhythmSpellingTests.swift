@testable import SheetMusicCore
import Testing

/// The splitter's expectations. Every table cell below is the output of the validated Python port
/// (`fmt_policy.py` over `ms_rhythm.py`), not a hand derivation. The port's "folino" knobs map to
/// `RhythmSpellingPolicy(.double, .split, .allow)`; `RhythmSpellingPolicy.default` has `beatCrossingRests:
/// .keepWritten`, which is a span-level rule and reads as `.split` inside the splitter.
@Suite("RhythmSpelling")
struct RhythmSpellingTests {
    static let division = 480

    static func fr(_ numerator: Int, _ denominator: Int = 1) -> Fraction {
        Fraction(numerator: numerator, denominator: denominator)
    }

    static func spell(
        _ length: Fraction, at start: Fraction, rest: Bool = false, meter: (Int, Int) = (4, 4),
        _ policy: RhythmSpellingPolicy = .default, pickup: Bool = false,
    ) -> [NoteDuration] {
        RhythmSpelling.durations(
            forTicks: length.ticks(division: division), startingAt: start.ticks(division: division), isRest: rest,
            meterNumerator: meter.0, meterDenominator: meter.1,
            barTicks: fr(meter.0, meter.1).ticks(division: division), isPickup: pickup,
            policy: policy, division: division,
        )
    }

    struct Row {
        let numerator: Int
        let denominator: Int
        let isRest: Bool
        let length: Fraction
        let start: Fraction
        let expected: [NoteDuration]
    }

    struct MeterRow {
        let numerator: Int
        let denominator: Int
        let isRest: Bool
        let length: Fraction
        let start: Fraction
        let expectedDefault: [NoteDuration]
        let expectedMuseScore: [NoteDuration]
    }

    static func row(
        _ numerator: Int, _ denominator: Int, _ isRest: Bool, _ length: Fraction, _ start: Fraction,
        _ expected: [NoteDuration],
    ) -> Row {
        Row(
            numerator: numerator, denominator: denominator, isRest: isRest, length: length, start: start,
            expected: expected,
        )
    }

    static func meterRow(
        _ numerator: Int, _ denominator: Int, _ isRest: Bool, _ length: Fraction, _ start: Fraction,
        _ expectedDefault: [NoteDuration], _ expectedMuseScore: [NoteDuration],
    ) -> MeterRow {
        MeterRow(
            numerator: numerator, denominator: denominator, isRest: isRest, length: length, start: start,
            expectedDefault: expectedDefault, expectedMuseScore: expectedMuseScore,
        )
    }

    /// The port's folino knobs: two dots, syncopations split, beat-crossing rests allowed.
    static func allowingRests(_ dots: RhythmSpellingPolicy.DotLevel) -> RhythmSpellingPolicy {
        RhythmSpellingPolicy(dotLevel: dots, midBarSyncopations: .split, beatCrossingRests: .allow)
    }

    static let tableDefault = allowingRests(.double)
    static let noDots = allowingRests(.none)
    static let tripleDots = allowingRests(.triple)

    static func check(_ rows: [Row], _ policy: RhythmSpellingPolicy) {
        for row in rows {
            let actual = spell(
                row.length, at: row.start, rest: row.isRest, meter: (row.numerator, row.denominator), policy,
            )
            #expect(
                actual == row.expected,
                "\(row.numerator)/\(row.denominator) \(row.isRest ? "rest" : "note") \(row.length) at \(row.start)",
            )
        }
    }

    // MARK: Acceptance cells (spec §3.3)

    @Test("brief examples")
    func briefExamples() {
        #expect(Self.spell(Self.fr(1, 2), at: Self.fr(3, 8)) == [.eighth, NoteDuration.quarter.dotted(1)])
        #expect(Self.spell(Self.fr(1, 2), at: Self.fr(1, 4)) == [.quarter, .quarter])
        #expect(Self.spell(Self.fr(1, 2), at: Self.fr(1, 4), .museScore) == [.half])
        #expect(Self.spell(Self.fr(7, 8), at: Self.fr(0)) == [NoteDuration.half.dotted(2)])
        #expect(Self.spell(Self.fr(1, 4), at: Self.fr(1, 8), rest: true, .museScore) == [.eighth, .eighth])
        #expect(Self.spell(Self.fr(1), at: Self.fr(0), rest: true) == [.measure])
    }

    @Test("every spec 3.3 row, default knobs")
    func tableDefaultRows() {
        Self.check(Self.defaultAllowRows, Self.tableDefault)
    }

    @Test("every spec 3.3 row, museScore preset")
    func tableMuseScoreRows() {
        Self.check(Self.museScoreRows, .museScore)
    }

    @Test("RhythmSpellingPolicy.default inside the splitter reads keepWritten as split")
    func defaultPresetRows() {
        Self.check(Self.swiftDefaultRows, .default)
        // The one visible difference from the table's knobs: a quarter rest off the beat splits.
        #expect(Self.spell(Self.fr(1, 4), at: Self.fr(1, 8), rest: true, .default) == [.eighth, .eighth])
        #expect(Self.spell(Self.fr(1, 4), at: Self.fr(1, 8), rest: true, Self.tableDefault) == [.quarter])
    }

    @Test("presets carry the spec's knob values")
    func presetValues() {
        #expect(RhythmSpellingPolicy.default == RhythmSpellingPolicy(
            dotLevel: .double, midBarSyncopations: .split, beatCrossingRests: .keepWritten,
        ))
        #expect(RhythmSpellingPolicy.museScore == RhythmSpellingPolicy(
            dotLevel: .single, midBarSyncopations: .allow, beatCrossingRests: .split,
        ))
    }

    // MARK: Dot levels

    @Test("dotLevel none: nothing is dotted")
    func dotLevelNone() {
        Self.check(Self.noneRows, Self.noDots)
        #expect(Self.spell(Self.fr(3, 4), at: Self.fr(0), meter: (3, 4), Self.noDots) == [.half, .quarter])
    }

    @Test("dotLevel triple")
    func dotLevelTriple() {
        Self.check(Self.tripleRows, Self.tripleDots)
        let spelled = Self.spell(Self.fr(3, 4), at: Self.fr(0), meter: (3, 4), Self.tripleDots)
        #expect(spelled == [NoteDuration.half.dotted(1)])
    }

    @Test("rests are capped at one dot whatever dotLevel says")
    func restsCapAtOneDot() {
        #expect(Self.spell(Self.fr(3, 8), at: Self.fr(0), rest: true, Self.tripleDots) == [.quarter, .eighth])
        #expect(
            Self.spell(Self.fr(3, 8), at: Self.fr(0), rest: true, meter: (6, 8), Self.tripleDots)
                == [NoteDuration.quarter.dotted(1)],
        )
        // The same span as a note keeps its dots, so the cap is the rest's alone.
        #expect(Self.spell(Self.fr(7, 8), at: Self.fr(0), Self.tripleDots) == [NoteDuration.half.dotted(2)])
        #expect(Self.spell(Self.fr(7, 8), at: Self.fr(0), rest: true, Self.tripleDots) == [.half, .quarter, .eighth])
    }

    // MARK: Meters

    @Test("meter families, default and museScore")
    func meterFamilies() {
        for row in Self.meterRows {
            let meter = (row.numerator, row.denominator)
            let kind = row.isRest ? "rest" : "note"
            let label = "\(row.numerator)/\(row.denominator) \(kind) \(row.length) at \(row.start)"
            let byDefault = Self.spell(row.length, at: row.start, rest: row.isRest, meter: meter, .default)
            let byMuseScore = Self.spell(row.length, at: row.start, rest: row.isRest, meter: meter, .museScore)
            #expect(byDefault == row.expectedDefault, "default \(label)")
            #expect(byMuseScore == row.expectedMuseScore, "museScore \(label)")
        }
    }

    // MARK: Measure rests, pickups, off-grid spans

    @Test("a rest as long as the bar is a measure rest; a note is not")
    func measureRest() {
        #expect(Self.spell(Self.fr(1), at: Self.fr(0), rest: true) == [.measure])
        #expect(Self.spell(Self.fr(3, 4), at: Self.fr(0), rest: true, meter: (3, 4)) == [.measure])
        #expect(Self.spell(Self.fr(1), at: Self.fr(0)) == [.whole])
        // A rest shorter than the bar never is.
        #expect(Self.spell(Self.fr(3, 4), at: Self.fr(0), rest: true) == [.half, .quarter])
    }

    @Test("a pickup is never a measure rest")
    func pickup() {
        // 3/4 of rests in a 4/4 pickup bar: the caller has shifted the start by the pickup's 1/4 offset.
        #expect(Self.spell(Self.fr(3, 4), at: Self.fr(1, 4), rest: true, pickup: true) == [.quarter, .half])
        #expect(!Self.spell(Self.fr(3, 4), at: Self.fr(1, 4), rest: true, pickup: true).contains(.measure))
        // `isPickup` only withdraws the `.measure` answer: a bar-long rest at 0 is spelled out instead.
        #expect(Self.spell(Self.fr(1), at: Self.fr(0), rest: true, pickup: true) == [.half, .half])
        #expect(Self.spell(Self.fr(1), at: Self.fr(0), rest: true, .museScore, pickup: true) == [.half, .half])
    }

    @Test("a span off any power-of-two grid is spelled longest-first")
    func greedyFallback() {
        // Starts a third of a quarter in: the meter cannot judge it, so greedy longest-first under the dot cap.
        #expect(Self.spell(Self.fr(7, 8), at: Self.fr(1, 12)) == [NoteDuration.half.dotted(2)])
        #expect(Self.spell(Self.fr(7, 8), at: Self.fr(1, 12), .museScore) == [NoteDuration.half.dotted(1), .eighth])
        #expect(Self.spell(Self.fr(3, 8), at: Self.fr(1, 12)) == [NoteDuration.quarter.dotted(1)])
        #expect(Self.spell(Self.fr(3, 8), at: Self.fr(1, 12), .museScore) == [NoteDuration.quarter.dotted(1)])
    }
}

extension RhythmSpellingTests {
    static let defaultAllowRows: [Row] = [
        row(4, 4, false, fr(1, 2), fr(3, 8), [.eighth, NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(5, 8), [NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(1, 8), [NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 4), fr(1, 4), [NoteDuration.half.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(3, 8), [.eighth, .quarter]),
        row(4, 4, false, fr(5, 8), fr(3, 8), [.eighth, .half]),
        row(4, 4, false, fr(1, 2), fr(1, 4), [.quarter, .quarter]),
        row(4, 4, false, fr(7, 8), fr(0, 1), [NoteDuration.half.dotted(2)]),
        row(4, 4, false, fr(7, 8), fr(1, 8), [NoteDuration.quarter.dotted(1), .half]),
        row(4, 4, true, fr(1, 4), fr(1, 8), [.quarter]),
        row(4, 4, true, fr(3, 8), fr(0, 1), [.quarter, .eighth]),
        row(4, 4, true, fr(1, 4), fr(3, 8), [.eighth, .eighth]),
        row(4, 4, true, fr(1, 1), fr(0, 1), [.measure]),
        row(6, 8, false, fr(1, 4), fr(1, 4), [.eighth, .eighth]),
        row(6, 8, true, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)]),
        row(6, 8, false, fr(3, 4), fr(0, 1), [NoteDuration.half.dotted(1)]),
        row(3, 4, true, fr(1, 2), fr(0, 1), [.half]),
        row(3, 4, true, fr(1, 2), fr(1, 4), [.half]),
        row(2, 4, true, fr(1, 4), fr(1, 8), [.quarter]),
        row(9, 8, true, fr(3, 4), fr(0, 1), [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)]),
        row(12, 8, false, fr(3, 4), fr(3, 8), [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(15, 16), fr(1, 16), [NoteDuration.quarter.dotted(2), .half]),
        row(4, 4, false, fr(15, 16), fr(0, 1), [.half, NoteDuration.quarter.dotted(2)]),
    ]
    static let museScoreRows: [Row] = [
        row(4, 4, false, fr(1, 2), fr(3, 8), [.eighth, NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(5, 8), [NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(1, 8), [NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 4), fr(1, 4), [NoteDuration.half.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(3, 8), [.eighth, .quarter]),
        row(4, 4, false, fr(5, 8), fr(3, 8), [.eighth, .half]),
        row(4, 4, false, fr(1, 2), fr(1, 4), [.half]),
        row(4, 4, false, fr(7, 8), fr(0, 1), [.half, NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(7, 8), fr(1, 8), [NoteDuration.quarter.dotted(1), .half]),
        row(4, 4, true, fr(1, 4), fr(1, 8), [.eighth, .eighth]),
        row(4, 4, true, fr(3, 8), fr(0, 1), [.quarter, .eighth]),
        row(4, 4, true, fr(1, 4), fr(3, 8), [.eighth, .eighth]),
        row(4, 4, true, fr(1, 1), fr(0, 1), [.measure]),
        row(6, 8, false, fr(1, 4), fr(1, 4), [.eighth, .eighth]),
        row(6, 8, true, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)]),
        row(6, 8, false, fr(3, 4), fr(0, 1), [NoteDuration.half.dotted(1)]),
        row(3, 4, true, fr(1, 2), fr(0, 1), [.quarter, .quarter]),
        row(3, 4, true, fr(1, 2), fr(1, 4), [.quarter, .quarter]),
        row(2, 4, true, fr(1, 4), fr(1, 8), [.eighth, .eighth]),
        row(9, 8, true, fr(3, 4), fr(0, 1), [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)]),
        row(12, 8, false, fr(3, 4), fr(3, 8), [NoteDuration.half.dotted(1)]),
        row(4, 4, false, fr(15, 16), fr(1, 16), [NoteDuration.eighth.dotted(1), .quarter, .half]),
        row(4, 4, false, fr(15, 16), fr(0, 1), [.half, .quarter, NoteDuration.eighth.dotted(1)]),
    ]
    static let noneRows: [Row] = [
        row(4, 4, false, fr(1, 2), fr(3, 8), [.eighth, .quarter, .eighth]),
        row(4, 4, false, fr(3, 8), fr(5, 8), [.eighth, .quarter]),
        row(4, 4, false, fr(3, 8), fr(1, 8), [.eighth, .quarter]),
        row(4, 4, false, fr(3, 8), fr(0, 1), [.quarter, .eighth]),
        row(4, 4, false, fr(3, 4), fr(1, 4), [.quarter, .half]),
        row(4, 4, false, fr(3, 8), fr(3, 8), [.eighth, .quarter]),
        row(4, 4, false, fr(5, 8), fr(3, 8), [.eighth, .half]),
        row(4, 4, false, fr(1, 2), fr(1, 4), [.quarter, .quarter]),
        row(4, 4, false, fr(7, 8), fr(0, 1), [.half, .quarter, .eighth]),
        row(4, 4, false, fr(7, 8), fr(1, 8), [.eighth, .quarter, .half]),
        row(4, 4, true, fr(1, 4), fr(1, 8), [.quarter]),
        row(4, 4, true, fr(3, 8), fr(0, 1), [.quarter, .eighth]),
        row(4, 4, true, fr(1, 4), fr(3, 8), [.eighth, .eighth]),
        row(4, 4, true, fr(1, 1), fr(0, 1), [.measure]),
        row(6, 8, false, fr(1, 4), fr(1, 4), [.eighth, .eighth]),
        row(6, 8, true, fr(3, 8), fr(0, 1), [.quarter, .eighth]),
        row(6, 8, false, fr(3, 4), fr(0, 1), [.quarter, .eighth, .quarter, .eighth]),
        row(3, 4, true, fr(1, 2), fr(0, 1), [.half]),
        row(3, 4, true, fr(1, 2), fr(1, 4), [.half]),
        row(2, 4, true, fr(1, 4), fr(1, 8), [.quarter]),
        row(9, 8, true, fr(3, 4), fr(0, 1), [.quarter, .eighth, .quarter, .eighth]),
        row(12, 8, false, fr(3, 4), fr(3, 8), [.quarter, .eighth, .quarter, .eighth]),
        row(4, 4, false, fr(15, 16), fr(1, 16), [.sixteenth, .eighth, .quarter, .half]),
        row(4, 4, false, fr(15, 16), fr(0, 1), [.half, .quarter, .eighth, .sixteenth]),
    ]
    static let tripleRows: [Row] = [
        row(4, 4, false, fr(1, 2), fr(3, 8), [.eighth, NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(5, 8), [NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(1, 8), [NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 4), fr(1, 4), [NoteDuration.half.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(3, 8), [.eighth, .quarter]),
        row(4, 4, false, fr(5, 8), fr(3, 8), [.eighth, .half]),
        row(4, 4, false, fr(1, 2), fr(1, 4), [.quarter, .quarter]),
        row(4, 4, false, fr(7, 8), fr(0, 1), [NoteDuration.half.dotted(2)]),
        row(4, 4, false, fr(7, 8), fr(1, 8), [NoteDuration.quarter.dotted(1), .half]),
        row(4, 4, true, fr(1, 4), fr(1, 8), [.quarter]),
        row(4, 4, true, fr(3, 8), fr(0, 1), [.quarter, .eighth]),
        row(4, 4, true, fr(1, 4), fr(3, 8), [.eighth, .eighth]),
        row(4, 4, true, fr(1, 1), fr(0, 1), [.measure]),
        row(6, 8, false, fr(1, 4), fr(1, 4), [.eighth, .eighth]),
        row(6, 8, true, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)]),
        row(6, 8, false, fr(3, 4), fr(0, 1), [NoteDuration.half.dotted(1)]),
        row(3, 4, true, fr(1, 2), fr(0, 1), [.half]),
        row(3, 4, true, fr(1, 2), fr(1, 4), [.half]),
        row(2, 4, true, fr(1, 4), fr(1, 8), [.quarter]),
        row(9, 8, true, fr(3, 4), fr(0, 1), [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)]),
        row(12, 8, false, fr(3, 4), fr(3, 8), [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(15, 16), fr(1, 16), [NoteDuration.quarter.dotted(2), .half]),
        row(4, 4, false, fr(15, 16), fr(0, 1), [NoteDuration.half.dotted(3)]),
    ]
    static let swiftDefaultRows: [Row] = [
        row(4, 4, false, fr(1, 2), fr(3, 8), [.eighth, NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(5, 8), [NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(1, 8), [NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(3, 4), fr(1, 4), [NoteDuration.half.dotted(1)]),
        row(4, 4, false, fr(3, 8), fr(3, 8), [.eighth, .quarter]),
        row(4, 4, false, fr(5, 8), fr(3, 8), [.eighth, .half]),
        row(4, 4, false, fr(1, 2), fr(1, 4), [.quarter, .quarter]),
        row(4, 4, false, fr(7, 8), fr(0, 1), [NoteDuration.half.dotted(2)]),
        row(4, 4, false, fr(7, 8), fr(1, 8), [NoteDuration.quarter.dotted(1), .half]),
        row(4, 4, true, fr(1, 4), fr(1, 8), [.eighth, .eighth]),
        row(4, 4, true, fr(3, 8), fr(0, 1), [.quarter, .eighth]),
        row(4, 4, true, fr(1, 4), fr(3, 8), [.eighth, .eighth]),
        row(4, 4, true, fr(1, 1), fr(0, 1), [.measure]),
        row(6, 8, false, fr(1, 4), fr(1, 4), [.eighth, .eighth]),
        row(6, 8, true, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)]),
        row(6, 8, false, fr(3, 4), fr(0, 1), [NoteDuration.half.dotted(1)]),
        row(3, 4, true, fr(1, 2), fr(0, 1), [.quarter, .quarter]),
        row(3, 4, true, fr(1, 2), fr(1, 4), [.quarter, .quarter]),
        row(2, 4, true, fr(1, 4), fr(1, 8), [.eighth, .eighth]),
        row(9, 8, true, fr(3, 4), fr(0, 1), [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)]),
        row(12, 8, false, fr(3, 4), fr(3, 8), [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)]),
        row(4, 4, false, fr(15, 16), fr(1, 16), [NoteDuration.quarter.dotted(2), .half]),
        row(4, 4, false, fr(15, 16), fr(0, 1), [.half, NoteDuration.quarter.dotted(2)]),
    ]
    /// (numerator, denominator, isRest, length, start, `.default`, `.museScore`)
    static let meterRows: [MeterRow] = [
        meterRow(2, 4, false, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(2, 4, true, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(2, 4, false, fr(1, 4), fr(1, 8), [.quarter], [.quarter]),
        meterRow(2, 4, true, fr(1, 4), fr(1, 8), [.eighth, .eighth], [.eighth, .eighth]),
        meterRow(2, 4, false, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(2, 4, true, fr(3, 8), fr(0, 1), [.quarter, .eighth], [.quarter, .eighth]),
        meterRow(2, 4, false, fr(3, 8), fr(1, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(2, 4, true, fr(3, 8), fr(1, 8), [.eighth, .quarter], [.eighth, .quarter]),
        meterRow(3, 4, false, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(3, 4, true, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(3, 4, false, fr(1, 4), fr(1, 8), [.quarter], [.quarter]),
        meterRow(3, 4, true, fr(1, 4), fr(1, 8), [.eighth, .eighth], [.eighth, .eighth]),
        meterRow(3, 4, false, fr(1, 4), fr(3, 8), [.quarter], [.quarter]),
        meterRow(3, 4, true, fr(1, 4), fr(3, 8), [.eighth, .eighth], [.eighth, .eighth]),
        meterRow(3, 4, false, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(3, 4, true, fr(3, 8), fr(0, 1), [.quarter, .eighth], [.quarter, .eighth]),
        meterRow(3, 4, false, fr(3, 8), fr(1, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(3, 4, true, fr(3, 8), fr(1, 8), [.eighth, .quarter], [.eighth, .quarter]),
        meterRow(3, 4, false, fr(3, 8), fr(3, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(3, 4, true, fr(3, 8), fr(3, 8), [.eighth, .quarter], [.eighth, .quarter]),
        meterRow(3, 4, false, fr(5, 8), fr(0, 1), [.half, .eighth], [.half, .eighth]),
        meterRow(3, 4, true, fr(5, 8), fr(0, 1), [.quarter, .quarter, .eighth], [.quarter, .quarter, .eighth]),
        meterRow(3, 4, false, fr(5, 8), fr(1, 8), [.eighth, .half], [.eighth, .half]),
        meterRow(3, 4, true, fr(5, 8), fr(1, 8), [.eighth, .quarter, .quarter], [.eighth, .quarter, .quarter]),
        meterRow(3, 4, false, fr(3, 4), fr(0, 1), [NoteDuration.half.dotted(1)], [NoteDuration.half.dotted(1)]),
        meterRow(3, 4, true, fr(3, 4), fr(0, 1), [.measure], [.measure]),
        meterRow(2, 2, false, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(2, 2, true, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(2, 2, false, fr(1, 4), fr(1, 8), [.quarter], [.quarter]),
        meterRow(2, 2, true, fr(1, 4), fr(1, 8), [.quarter], [.quarter]),
        meterRow(2, 2, false, fr(1, 4), fr(3, 8), [.quarter], [.quarter]),
        meterRow(2, 2, true, fr(1, 4), fr(3, 8), [.eighth, .eighth], [.eighth, .eighth]),
        meterRow(2, 2, false, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(2, 2, true, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(2, 2, false, fr(3, 8), fr(1, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(2, 2, true, fr(3, 8), fr(1, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(2, 2, false, fr(3, 8), fr(3, 8), [.eighth, .quarter], [.eighth, .quarter]),
        meterRow(2, 2, true, fr(3, 8), fr(3, 8), [.eighth, .quarter], [.eighth, .quarter]),
        meterRow(2, 2, false, fr(5, 8), fr(0, 1), [.half, .eighth], [.half, .eighth]),
        meterRow(2, 2, true, fr(5, 8), fr(0, 1), [.half, .eighth], [.half, .eighth]),
        meterRow(
            2, 2, false, fr(5, 8), fr(1, 8),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(
            2, 2, true, fr(5, 8), fr(1, 8),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(2, 2, false, fr(5, 8), fr(3, 8), [.eighth, .half], [.eighth, .half]),
        meterRow(2, 2, true, fr(5, 8), fr(3, 8), [.eighth, .half], [.eighth, .half]),
        meterRow(2, 2, false, fr(3, 4), fr(0, 1), [NoteDuration.half.dotted(1)], [NoteDuration.half.dotted(1)]),
        meterRow(2, 2, true, fr(3, 4), fr(0, 1), [.half, .quarter], [.half, .quarter]),
        meterRow(2, 2, false, fr(3, 4), fr(1, 8), [NoteDuration.half.dotted(1)], [NoteDuration.half.dotted(1)]),
        meterRow(
            2, 2, true, fr(3, 4), fr(1, 8),
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
        ),
        meterRow(3, 8, false, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(3, 8, true, fr(1, 4), fr(0, 1), [.eighth, .eighth], [.eighth, .eighth]),
        meterRow(3, 8, false, fr(1, 4), fr(1, 8), [.quarter], [.quarter]),
        meterRow(3, 8, true, fr(1, 4), fr(1, 8), [.eighth, .eighth], [.eighth, .eighth]),
        meterRow(3, 8, false, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(3, 8, true, fr(3, 8), fr(0, 1), [.measure], [.measure]),
        meterRow(6, 8, false, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(6, 8, true, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(6, 8, false, fr(1, 4), fr(1, 8), [.quarter], [.quarter]),
        meterRow(6, 8, true, fr(1, 4), fr(1, 8), [.eighth, .eighth], [.eighth, .eighth]),
        meterRow(6, 8, false, fr(1, 4), fr(3, 8), [.quarter], [.quarter]),
        meterRow(6, 8, true, fr(1, 4), fr(3, 8), [.quarter], [.quarter]),
        meterRow(6, 8, false, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(6, 8, true, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(6, 8, false, fr(3, 8), fr(1, 8), [.quarter, .eighth], [.quarter, .eighth]),
        meterRow(6, 8, true, fr(3, 8), fr(1, 8), [.eighth, .eighth, .eighth], [.eighth, .eighth, .eighth]),
        meterRow(6, 8, false, fr(3, 8), fr(3, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(6, 8, true, fr(3, 8), fr(3, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(
            6, 8, false, fr(5, 8), fr(0, 1),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(
            6, 8, true, fr(5, 8), fr(0, 1),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(
            6, 8, false, fr(5, 8), fr(1, 8),
            [.quarter, NoteDuration.quarter.dotted(1)],
            [.quarter, NoteDuration.quarter.dotted(1)],
        ),
        meterRow(
            6, 8, true, fr(5, 8), fr(1, 8),
            [.eighth, .eighth, NoteDuration.quarter.dotted(1)],
            [.eighth, .eighth, NoteDuration.quarter.dotted(1)],
        ),
        meterRow(6, 8, false, fr(3, 4), fr(0, 1), [NoteDuration.half.dotted(1)], [NoteDuration.half.dotted(1)]),
        meterRow(6, 8, true, fr(3, 4), fr(0, 1), [.measure], [.measure]),
        meterRow(9, 8, false, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(9, 8, true, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(9, 8, false, fr(1, 4), fr(1, 8), [.quarter], [.quarter]),
        meterRow(9, 8, true, fr(1, 4), fr(1, 8), [.eighth, .eighth], [.eighth, .eighth]),
        meterRow(9, 8, false, fr(1, 4), fr(3, 8), [.quarter], [.quarter]),
        meterRow(9, 8, true, fr(1, 4), fr(3, 8), [.quarter], [.quarter]),
        meterRow(9, 8, false, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(9, 8, true, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(9, 8, false, fr(3, 8), fr(1, 8), [.quarter, .eighth], [.quarter, .eighth]),
        meterRow(9, 8, true, fr(3, 8), fr(1, 8), [.eighth, .eighth, .eighth], [.eighth, .eighth, .eighth]),
        meterRow(9, 8, false, fr(3, 8), fr(3, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(9, 8, true, fr(3, 8), fr(3, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(
            9, 8, false, fr(5, 8), fr(0, 1),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(
            9, 8, true, fr(5, 8), fr(0, 1),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(
            9, 8, false, fr(5, 8), fr(1, 8),
            [.quarter, NoteDuration.quarter.dotted(1)],
            [.quarter, NoteDuration.quarter.dotted(1)],
        ),
        meterRow(
            9, 8, true, fr(5, 8), fr(1, 8),
            [.eighth, .eighth, NoteDuration.quarter.dotted(1)],
            [.eighth, .eighth, NoteDuration.quarter.dotted(1)],
        ),
        meterRow(
            9, 8, false, fr(5, 8), fr(3, 8),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(
            9, 8, true, fr(5, 8), fr(3, 8),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(9, 8, false, fr(3, 4), fr(0, 1), [NoteDuration.half.dotted(1)], [NoteDuration.half.dotted(1)]),
        meterRow(
            9, 8, true, fr(3, 4), fr(0, 1),
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
        ),
        meterRow(
            9, 8, false, fr(3, 4), fr(1, 8),
            [.quarter, NoteDuration.quarter.dotted(1), .eighth],
            [.quarter, NoteDuration.quarter.dotted(1), .eighth],
        ),
        meterRow(
            9, 8, true, fr(3, 4), fr(1, 8),
            [.eighth, .eighth, NoteDuration.quarter.dotted(1), .eighth],
            [.eighth, .eighth, NoteDuration.quarter.dotted(1), .eighth],
        ),
        meterRow(9, 8, false, fr(3, 4), fr(3, 8), [NoteDuration.half.dotted(1)], [NoteDuration.half.dotted(1)]),
        meterRow(
            9, 8, true, fr(3, 4), fr(3, 8),
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
        ),
        meterRow(12, 8, false, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(12, 8, true, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(12, 8, false, fr(1, 4), fr(1, 8), [.quarter], [.quarter]),
        meterRow(12, 8, true, fr(1, 4), fr(1, 8), [.eighth, .eighth], [.eighth, .eighth]),
        meterRow(12, 8, false, fr(1, 4), fr(3, 8), [.quarter], [.quarter]),
        meterRow(12, 8, true, fr(1, 4), fr(3, 8), [.quarter], [.quarter]),
        meterRow(12, 8, false, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(12, 8, true, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(12, 8, false, fr(3, 8), fr(1, 8), [.quarter, .eighth], [.quarter, .eighth]),
        meterRow(12, 8, true, fr(3, 8), fr(1, 8), [.eighth, .eighth, .eighth], [.eighth, .eighth, .eighth]),
        meterRow(12, 8, false, fr(3, 8), fr(3, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(12, 8, true, fr(3, 8), fr(3, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(
            12, 8, false, fr(5, 8), fr(0, 1),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(
            12, 8, true, fr(5, 8), fr(0, 1),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(
            12, 8, false, fr(5, 8), fr(1, 8),
            [.quarter, NoteDuration.quarter.dotted(1)],
            [.quarter, NoteDuration.quarter.dotted(1)],
        ),
        meterRow(
            12, 8, true, fr(5, 8), fr(1, 8),
            [.eighth, .eighth, NoteDuration.quarter.dotted(1)],
            [.eighth, .eighth, NoteDuration.quarter.dotted(1)],
        ),
        meterRow(
            12, 8, false, fr(5, 8), fr(3, 8),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(
            12, 8, true, fr(5, 8), fr(3, 8),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(12, 8, false, fr(3, 4), fr(0, 1), [NoteDuration.half.dotted(1)], [NoteDuration.half.dotted(1)]),
        meterRow(12, 8, true, fr(3, 4), fr(0, 1), [NoteDuration.half.dotted(1)], [NoteDuration.half.dotted(1)]),
        meterRow(
            12, 8, false, fr(3, 4), fr(1, 8),
            [.quarter, NoteDuration.quarter.dotted(1), .eighth],
            [.quarter, NoteDuration.quarter.dotted(1), .eighth],
        ),
        meterRow(
            12, 8, true, fr(3, 4), fr(1, 8),
            [.eighth, .eighth, NoteDuration.quarter.dotted(1), .eighth],
            [.eighth, .eighth, NoteDuration.quarter.dotted(1), .eighth],
        ),
        meterRow(
            12, 8, false, fr(3, 4), fr(3, 8),
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
            [NoteDuration.half.dotted(1)],
        ),
        meterRow(
            12, 8, true, fr(3, 4), fr(3, 8),
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
        ),
        meterRow(5, 8, false, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(5, 8, true, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(5, 8, false, fr(1, 4), fr(1, 8), [.quarter], [.quarter]),
        meterRow(5, 8, true, fr(1, 4), fr(1, 8), [.quarter], [.quarter]),
        meterRow(5, 8, false, fr(1, 4), fr(3, 8), [.quarter], [.quarter]),
        meterRow(5, 8, true, fr(1, 4), fr(3, 8), [.quarter], [.quarter]),
        meterRow(5, 8, false, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(5, 8, true, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(5, 8, false, fr(3, 8), fr(1, 8), [.quarter, .eighth], [.quarter, .eighth]),
        meterRow(5, 8, true, fr(3, 8), fr(1, 8), [.quarter, .eighth], [.quarter, .eighth]),
        meterRow(
            5, 8, false, fr(5, 8), fr(0, 1),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(5, 8, true, fr(5, 8), fr(0, 1), [.measure], [.measure]),
        meterRow(7, 8, false, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(7, 8, true, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(7, 8, false, fr(1, 4), fr(1, 8), [.quarter], [.quarter]),
        meterRow(7, 8, true, fr(1, 4), fr(1, 8), [.quarter], [.quarter]),
        meterRow(7, 8, false, fr(1, 4), fr(3, 8), [.eighth, .eighth], [.eighth, .eighth]),
        meterRow(7, 8, true, fr(1, 4), fr(3, 8), [.eighth, .eighth], [.eighth, .eighth]),
        meterRow(7, 8, false, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(7, 8, true, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(7, 8, false, fr(3, 8), fr(1, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(7, 8, true, fr(3, 8), fr(1, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(7, 8, false, fr(3, 8), fr(3, 8), [.eighth, .quarter], [.eighth, .quarter]),
        meterRow(7, 8, true, fr(3, 8), fr(3, 8), [.eighth, .quarter], [.eighth, .quarter]),
        meterRow(7, 8, false, fr(5, 8), fr(0, 1), [.half, .eighth], [.half, .eighth]),
        meterRow(7, 8, true, fr(5, 8), fr(0, 1), [.half, .eighth], [.half, .eighth]),
        meterRow(
            7, 8, false, fr(5, 8), fr(1, 8),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(
            7, 8, true, fr(5, 8), fr(1, 8),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(7, 8, false, fr(3, 4), fr(0, 1), [.half, .quarter], [.half, .quarter]),
        meterRow(7, 8, true, fr(3, 4), fr(0, 1), [.half, .quarter], [.half, .quarter]),
        meterRow(
            7, 8, false, fr(3, 4), fr(1, 8),
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
        ),
        meterRow(
            7, 8, true, fr(3, 4), fr(1, 8),
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
        ),
        meterRow(5, 4, false, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(5, 4, true, fr(1, 4), fr(0, 1), [.quarter], [.quarter]),
        meterRow(5, 4, false, fr(1, 4), fr(1, 8), [.quarter], [.quarter]),
        meterRow(5, 4, true, fr(1, 4), fr(1, 8), [.eighth, .eighth], [.eighth, .eighth]),
        meterRow(5, 4, false, fr(1, 4), fr(3, 8), [.quarter], [.quarter]),
        meterRow(5, 4, true, fr(1, 4), fr(3, 8), [.eighth, .eighth], [.eighth, .eighth]),
        meterRow(5, 4, false, fr(3, 8), fr(0, 1), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(5, 4, true, fr(3, 8), fr(0, 1), [.quarter, .eighth], [.quarter, .eighth]),
        meterRow(5, 4, false, fr(3, 8), fr(1, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(5, 4, true, fr(3, 8), fr(1, 8), [.eighth, .quarter], [.eighth, .quarter]),
        meterRow(5, 4, false, fr(3, 8), fr(3, 8), [NoteDuration.quarter.dotted(1)], [NoteDuration.quarter.dotted(1)]),
        meterRow(5, 4, true, fr(3, 8), fr(3, 8), [.eighth, .quarter], [.eighth, .quarter]),
        meterRow(5, 4, false, fr(5, 8), fr(0, 1), [.half, .eighth], [.half, .eighth]),
        meterRow(5, 4, true, fr(5, 8), fr(0, 1), [.half, .eighth], [.half, .eighth]),
        meterRow(5, 4, false, fr(5, 8), fr(1, 8), [.eighth, .half], [.eighth, .half]),
        meterRow(5, 4, true, fr(5, 8), fr(1, 8), [.eighth, .half], [.eighth, .half]),
        meterRow(
            5, 4, false, fr(5, 8), fr(3, 8),
            [NoteDuration.quarter.dotted(1), .quarter],
            [NoteDuration.quarter.dotted(1), .quarter],
        ),
        meterRow(5, 4, true, fr(5, 8), fr(3, 8), [.eighth, .quarter, .quarter], [.eighth, .quarter, .quarter]),
        meterRow(5, 4, false, fr(3, 4), fr(0, 1), [NoteDuration.half.dotted(1)], [NoteDuration.half.dotted(1)]),
        meterRow(5, 4, true, fr(3, 4), fr(0, 1), [NoteDuration.half.dotted(1)], [NoteDuration.half.dotted(1)]),
        meterRow(5, 4, false, fr(3, 4), fr(1, 8), [.eighth, .half, .eighth], [.eighth, .half, .eighth]),
        meterRow(5, 4, true, fr(3, 4), fr(1, 8), [.eighth, .half, .eighth], [.eighth, .half, .eighth]),
        meterRow(
            5, 4, false, fr(3, 4), fr(3, 8),
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
            [NoteDuration.quarter.dotted(1), NoteDuration.quarter.dotted(1)],
        ),
        meterRow(
            5, 4, true, fr(3, 4), fr(3, 8),
            [.eighth, .quarter, .quarter, .eighth],
            [.eighth, .quarter, .quarter, .eighth],
        ),
    ]
}
