@testable import SheetMusicCore
import Testing

/// What a moved barline does to the things that only mean something ON a barline, and to the chords it cuts.
///
/// `RebarPlannerTests` covers the partitioning itself; this suite covers the two surfaces that hang off it —
/// `RebarPlanner+Markers` (rule 7: the HARD set refuses when the new grid has no barline at its tick, the
/// SOFT set re-homes best-effort) and a chord long enough for the new grid to cut it more than once.
///
/// Every expectation about how a split lands is computed with `DurationChangeAlgorithm.alignedDurations`
/// rather than hand-guessed, so a change to the beat-alignment rule moves the planner and these tests
/// together.
@Suite("RebarPlanner barlines")
struct RebarPlannerBarlineTests {
    private static let division = 480

    // MARK: - Fixtures

    private static func score(_ measures: [Measure]) -> Score {
        let staff = Staff(measures: measures)
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
        return Score(
            division: division,
            parts: [part],
            systemMeasures: Array(repeating: SystemMeasure(), count: measures.count),
        )
    }

    private static func note(_ pitch: Int = 72, tieForward: Int? = nil, tieBack: Int? = nil) -> Note {
        Note(pitch: pitch, tpc: 14, tieForward: tieForward, tieBack: tieBack)
    }

    private static func chord(
        _ duration: NoteDuration, pitch: Int = 72, tieForward: Int? = nil, tieBack: Int? = nil,
    ) -> VoiceElement {
        .chord(Chord(
            duration: duration,
            notes: [note(pitch, tieForward: tieForward, tieBack: tieBack)],
        ))
    }

    private static let timeSignature44 = VoiceElement.timeSignature(
        TimeSignature(numerator: 4, denominator: 4),
    )

    /// Three 4/4 bars, one whole note each — 5760 ticks. In 2/4 that is six columns whose barlines fall on
    /// every old one (0, 1920, 3840, 5760); in 3/4 it is four columns whose barlines fall at 1440, 2880 and
    /// 4320, i.e. on NONE of them. So the same marker survives the first re-bar and is refused by the second,
    /// which is exactly the pair rule 7 describes.
    private static func threeWholeNotesIn44(
        markingBarOne mark: (inout Measure) -> Void = { _ in },
    ) -> Score {
        var middle = Measure(voices: [Voice(elements: [chord(.whole)])])
        mark(&middle)
        return score([
            Measure(voices: [Voice(elements: [timeSignature44, chord(.whole)])]),
            middle,
            Measure(voices: [Voice(elements: [chord(.whole)])]),
        ])
    }

    // MARK: - Readers

    private static func voice0(_ rebarred: RebarPlanner.Rebarred, _ column: Int) -> Voice {
        rebarred.columns[column].staffMeasures[0][0].voices[0]
    }

    private static func measure(_ rebarred: RebarPlanner.Rebarred, _ column: Int) -> Measure {
        rebarred.columns[column].staffMeasures[0][0]
    }

    /// Elements of a column's voice 0 with the leading signature run stripped — the timed content alone.
    private static func content(_ rebarred: RebarPlanner.Rebarred, _ column: Int) -> [VoiceElement] {
        let elements = voice0(rebarred, column).elements
        return Array(elements.drop(while: MeasureStructure.isLeadingSignature))
    }

    private static func durations(_ elements: [VoiceElement]) -> [NoteDuration] {
        elements.compactMap {
            if case let .chord(chord) = $0 { chord.duration } else { nil }
        }
    }

    /// The SOUNDING chords only. A rest is an empty `.chord` in this model, so a plain `case .chord` filter
    /// would sweep the padding rests into the tie chain.
    private static func soundingChords(_ elements: [VoiceElement]) -> [Chord] {
        elements.compactMap {
            if case let .chord(chord) = $0, !chord.notes.isEmpty { chord } else { nil }
        }
    }

    private static func aligned(_ ticks: Int, from rtickStart: Int) -> [NoteDuration] {
        DurationChangeAlgorithm.alignedDurations(
            forTicks: ticks, rtickStart: rtickStart, division: division,
        )
    }

    private static func alignedRests(_ ticks: Int, from rtickStart: Int) -> [VoiceElement] {
        DurationChangeAlgorithm.alignedRests(
            forTicks: ticks, rtickStart: rtickStart, division: division,
        )
    }

    private static func refusalReason(_ body: () throws -> Void) -> EditRefusal.Reason? {
        do {
            try body()
            return nil
        } catch let SheetMusicError.invalidEdit(refusal) {
            return refusal.reason
        } catch {
            Issue.record("unexpected error: \(error)")
            return nil
        }
    }

    // MARK: - Hard set: end repeat

    @Test("an end repeat that stays on a new boundary re-homes onto the column that ends there")
    func endRepeatSurvivesOnBoundary() throws {
        let score = Self.threeWholeNotesIn44 { $0.endRepeatCount = 2 }
        let plan = try RebarPlanner.rebar(region: 0 ..< 3, in: score, numerator: 2, denominator: 4)
        #expect(plan.columns.count == 6)
        // Bar 2 ends at 3840, which is where column 3 ends: the repeat closes that column instead.
        #expect(plan.columns.map { $0.staffMeasures[0][0].endRepeatCount }
            == [nil, nil, nil, 2, nil, nil])
    }

    @Test("an end repeat the new barring would displace is refused")
    func endRepeatDisplacedRefused() {
        let score = Self.threeWholeNotesIn44 { $0.endRepeatCount = 2 }
        let reason = Self.refusalReason {
            _ = try RebarPlanner.rebar(region: 0 ..< 3, in: score, numerator: 3, denominator: 4)
        }
        #expect(reason == .rebarWouldDisplaceBarlineMarker(measureIndex: 1))
    }

    // MARK: - Hard set: Marker and Jump

    @Test("a Segno and a D.C. re-home onto the columns that open and close their bar")
    func markerAndJumpSurviveOnBoundary() throws {
        let segno = Marker(kind: .segno, label: "segno", text: "Segno")
        let daCapo = Jump(jumpTo: "start", playUntil: "end", text: "D.C.")
        let score = Self.threeWholeNotesIn44 {
            $0.markers = [segno]
            $0.jumps = [daCapo]
        }
        let plan = try RebarPlanner.rebar(region: 0 ..< 3, in: score, numerator: 2, denominator: 4)
        #expect(plan.columns.count == 6)
        // A Marker is anchored at the bar's LEFT edge (1920 = the head of column 2), a Jump at its RIGHT
        // one (3840 = the end of column 3).
        #expect(plan.columns.map { $0.staffMeasures[0][0].markers } == [[], [], [segno], [], [], []])
        #expect(plan.columns.map { $0.staffMeasures[0][0].jumps } == [[], [], [], [daCapo], [], []])
    }

    @Test("a Segno the new barring would displace is refused")
    func markerDisplacedRefused() {
        let score = Self.threeWholeNotesIn44 { $0.markers = [Marker(kind: .segno, label: "segno")] }
        let reason = Self.refusalReason {
            _ = try RebarPlanner.rebar(region: 0 ..< 3, in: score, numerator: 3, denominator: 4)
        }
        #expect(reason == .rebarWouldDisplaceBarlineMarker(measureIndex: 1))
    }

    @Test("a D.C. the new barring would displace is refused")
    func jumpDisplacedRefused() {
        let score = Self.threeWholeNotesIn44 {
            $0.jumps = [Jump(jumpTo: "start", playUntil: "end", text: "D.C.")]
        }
        let reason = Self.refusalReason {
            _ = try RebarPlanner.rebar(region: 0 ..< 3, in: score, numerator: 3, denominator: 4)
        }
        #expect(reason == .rebarWouldDisplaceBarlineMarker(measureIndex: 1))
    }

    // MARK: - Hard set: a special barline element

    @Test("a special barline re-homes to the head or the tail of the column at its own tick")
    func specialBarLineSurvivesOnBoundary() throws {
        let opening = VoiceElement.barLine(BarLine(subtype: "start-repeat"))
        let double = VoiceElement.barLine(BarLine(subtype: "double"))
        let score = Self.score([
            // A `.barLine` rides in voice 0: at the head after the bar's signatures, or at the tail after
            // everything — which is where the decoder reads one from and the encoder writes it back to.
            Measure(voices: [Voice(elements: [Self.timeSignature44, opening, Self.chord(.whole), double])]),
            Measure(voices: [Voice(elements: [Self.chord(.whole)])]),
        ])
        let plan = try RebarPlanner.rebar(region: 0 ..< 2, in: score, numerator: 2, denominator: 4)
        #expect(plan.columns.count == 4)
        // The opening barline sits at tick 0 — the run's own start, which nothing has moved under.
        #expect(Self.content(plan, 0).first == opening)
        // The closing one sits at 1920, where column 1 ends.
        #expect(Self.voice0(plan, 1).elements.last == double)
        #expect(!Self.voice0(plan, 2).elements.contains(double))
    }

    @Test("a special barline the new barring would displace is refused")
    func specialBarLineDisplacedRefused() {
        let score = Self.score([
            Measure(voices: [Voice(elements: [
                Self.timeSignature44, Self.chord(.whole), .barLine(BarLine(subtype: "double")),
            ])]),
            Measure(voices: [Voice(elements: [Self.chord(.whole)])]),
            Measure(voices: [Voice(elements: [Self.chord(.whole)])]),
        ])
        // 3/4 columns fall at 1440 / 2880 / 4320; the barline is at 1920.
        let reason = Self.refusalReason {
            _ = try RebarPlanner.rebar(region: 0 ..< 3, in: score, numerator: 3, denominator: 4)
        }
        #expect(reason == .rebarWouldDisplaceBarlineMarker(measureIndex: 0))
    }

    // MARK: - Soft set: layout breaks and the measure-repeat count

    @Test("a line break with no new boundary at its tick re-homes best-effort instead of refusing")
    func lineBreakOffBoundaryRehomesWithoutRefusing() throws {
        let score = Self.threeWholeNotesIn44 { $0.lineBreak = true }
        // 3/4 has no barline at bar 2's end (3840) — a repeat or a Jump there would be refused. A layout
        // break is a typesetting hint, not a navigation landmark, so it lands on the column holding the
        // tick just inside its bar: 3839 is in column 2 (2880 ..< 4320).
        let plan = try RebarPlanner.rebar(region: 0 ..< 3, in: score, numerator: 3, denominator: 4)
        #expect(plan.columns.count == 4)
        #expect(plan.columns.map { $0.staffMeasures[0][0].lineBreak } == [false, false, true, false])
    }

    @Test("a section break off the new grid re-homes the same best-effort way")
    func sectionBreakOffBoundaryRehomesWithoutRefusing() throws {
        let score = Self.threeWholeNotesIn44 { $0.sectionBreak = true }
        let plan = try RebarPlanner.rebar(region: 0 ..< 3, in: score, numerator: 3, denominator: 4)
        #expect(plan.columns.map { $0.staffMeasures[0][0].sectionBreak } == [false, false, true, false])
    }

    @Test("a measure-repeat count off the new grid re-homes to the column holding its bar's start")
    func measureRepeatCountOffBoundaryRehomesWithoutRefusing() throws {
        let score = Self.threeWholeNotesIn44 { $0.measureRepeatCount = 2 }
        // Bar 2 starts at 1920, inside column 1 (1440 ..< 2880): start-anchored, and NOT in the hard set.
        let plan = try RebarPlanner.rebar(region: 0 ..< 3, in: score, numerator: 3, denominator: 4)
        #expect(plan.columns.map { $0.staffMeasures[0][0].measureRepeatCount } == [nil, 2, nil, nil])
    }

    // MARK: - A chord the new grid cuts more than once

    @Test("a whole note re-barred into 3/8 comes out as one tied chain across three columns")
    func chordCrossingSeveralNewBarlines() throws {
        let grace = GraceChord(graceType: .grace16after, duration: .sixteenth, notes: [Self.note(74)])
        var tied = Chord(duration: .whole, notes: [Self.note(tieBack: 1)])
        tied.lyrics = [Lyric(text: "ah")]
        tied.graceNotesAfter = [grace]
        let score = Self.score([
            Measure(voices: [Voice(elements: [Self.timeSignature44, Self.chord(.whole, tieForward: 1)])]),
            Measure(voices: [Voice(elements: [.chord(tied)])]),
        ])
        // Only bar 2 is re-barred, so its chord really is tied in from OUTSIDE the region. 1920 ticks at
        // 720 per column is three columns, cut at 720 and again at 1440 — two new barlines, not one.
        let plan = try RebarPlanner.rebar(region: 1 ..< 2, in: score, numerator: 3, denominator: 8)
        #expect(plan.columns.count == 3)
        #expect(Self.durations(Self.content(plan, 0)) == Self.aligned(720, from: 0))
        #expect(Self.durations(Self.content(plan, 1)) == Self.aligned(720, from: 0))
        // The last column runs to 2160 and the chain stops at 1920, so its remainder is padded with rests.
        #expect(Self.durations(Self.content(plan, 2))
            == Self.aligned(480, from: 0) + Self.aligned(240, from: 480))
        #expect(Array(Self.content(plan, 2).dropFirst()) == Self.alignedRests(240, from: 480))

        let chain = (0 ..< 3).flatMap { Self.soundingChords(Self.content(plan, $0)) }
        #expect(chain.count == 5)
        guard let head = chain.first, let tail = chain.last, chain.count == 5 else { return }

        // ONE chain over every piece, not one per column: the head keeps what the source was tied to, and
        // only the last piece decides where the chain stops.
        #expect(head.notes[0].tieBack == 1)
        #expect(head.notes[0].tieForward == 1)
        #expect(head.lyrics.map(\.text) == ["ah"])
        #expect(head.graceNotesAfter.isEmpty)

        for joint in chain.dropFirst().dropLast() {
            #expect(joint.notes[0].tieBack == 1)
            #expect(joint.notes[0].tieForward == 1)
            #expect(joint.lyrics.isEmpty)
            #expect(joint.graceNotesAfter.isEmpty)
        }

        // The source chord ended its own tie, so the chain's tail does too — and the graces that lead out
        // of the sound ride the last piece rather than the head.
        #expect(tail.notes[0].tieBack == 1)
        #expect(tail.notes[0].tieForward == nil)
        #expect(tail.graceNotesAfter == [grace])
    }
}
