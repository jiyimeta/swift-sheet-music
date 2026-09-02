@testable import SheetMusicCore
import Testing

/// `RebarPlanner` re-partitions a measure region at a new nominal meter. Every expectation about how a
/// split lands is computed with `DurationChangeAlgorithm.alignedDurations` rather than hand-guessed, so a
/// change to the beat-alignment rule moves the planner and these tests together.
@Suite("RebarPlanner")
struct RebarPlannerTests {
    private static let division = 480
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    // MARK: - Fixtures

    private static func score(
        _ measures: [Measure], systemMeasures: [SystemMeasure]? = nil,
    ) -> Score {
        let staff = Staff(measures: measures)
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
        return Score(
            division: division,
            parts: [part],
            systemMeasures: systemMeasures
                ?? Array(repeating: SystemMeasure(), count: measures.count),
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

    /// Two 4/4 bars, each a single whole note. Bar 0 declares the meter.
    private static func twoWholeNotesIn44() -> Score {
        score([
            Measure(voices: [Voice(elements: [timeSignature44, chord(.whole)])]),
            Measure(voices: [Voice(elements: [chord(.whole)])]),
        ])
    }

    // MARK: - Readers

    private static func voice0(_ rebarred: RebarPlanner.Rebarred, _ column: Int) -> Voice {
        rebarred.columns[column].staffMeasures[0][0].voices[0]
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

    /// A `<location>` jog, written the way the MSCX decoder writes one: a fraction-of-a-whole-note delta.
    private static func jog(_ numerator: Int, _ denominator: Int) -> VoiceElement {
        .locationShift(delta: Fraction(numerator: numerator, denominator: denominator))
    }

    private static func shifts(_ elements: [VoiceElement]) -> [Fraction] {
        elements.compactMap {
            if case let .locationShift(delta) = $0 { delta } else { nil }
        }
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

    // MARK: - Shrink

    @Test("4/4 to 3/4 re-bars two bars into three beat-aligned columns")
    func shrinkFourFourToThreeFour() throws {
        let plan = try RebarPlanner.rebar(
            region: 0 ..< 2, in: Self.twoWholeNotesIn44(), numerator: 3, denominator: 4,
        )
        #expect(plan.columns.count == 3)

        // Bar 1's whole note (0..<1920) is cut at 1440; bar 2's (1920..<3840) at 2880. The last column runs
        // to 4320 and is padded.
        #expect(Self.durations(Self.content(plan, 0)) == Self.aligned(1440, from: 0))
        #expect(Self.durations(Self.content(plan, 1))
            == Self.aligned(480, from: 0) + Self.aligned(960, from: 480))
        #expect(Self.durations(Self.content(plan, 2))
            == Self.aligned(960, from: 0) + Self.aligned(480, from: 960))

        // Every regular column carries the nominal duration, never an explicit length.
        for column in plan.columns {
            #expect(column.staffMeasures[0][0].actualLength == nil)
        }
    }

    @Test("the first regular column declares the new meter, and old ones are dropped")
    func firstColumnDeclaresNewMeter() throws {
        let plan = try RebarPlanner.rebar(
            region: 0 ..< 2, in: Self.twoWholeNotesIn44(), numerator: 3, denominator: 4,
        )
        #expect(Self.voice0(plan, 0).elements.first == .timeSignature(
            TimeSignature(numerator: 3, denominator: 4),
        ))
        let laterSignatures = plan.columns.dropFirst().flatMap { column in
            column.staffMeasures.flatMap { $0.flatMap { $0.voices.flatMap(\.elements) } }
        }.filter { if case .timeSignature = $0 { true } else { false } }
        #expect(laterSignatures.isEmpty)
    }

    @Test("emitsLeadingSignature false writes no meter at all, with identical partitioning")
    func suppressedLeadingSignature() throws {
        let score = Self.twoWholeNotesIn44()
        let withSignature = try RebarPlanner.rebar(
            region: 0 ..< 2, in: score, numerator: 3, denominator: 4,
        )
        let without = try RebarPlanner.rebar(
            region: 0 ..< 2, in: score, numerator: 3, denominator: 4, emitsLeadingSignature: false,
        )
        let signatures = without.columns.flatMap { column in
            column.staffMeasures.flatMap { $0.flatMap { $0.voices.flatMap(\.elements) } }
        }.filter { if case .timeSignature = $0 { true } else { false } }
        #expect(signatures.isEmpty)

        #expect(without.columns.count == withSignature.columns.count)
        for column in without.columns.indices {
            #expect(Self.content(without, column) == Self.content(withSignature, column))
        }
    }

    // MARK: - Grow

    @Test("3/4 to 4/4 splits a tied chain further instead of merging it")
    func growThreeFourToFourFourKeepsTieChain() throws {
        let score = Self.score([
            Measure(voices: [Voice(elements: [
                .timeSignature(TimeSignature(numerator: 3, denominator: 4)),
                Self.chord(.quarter),
                Self.chord(.half, tieForward: 1),
            ])]),
            Measure(voices: [Voice(elements: [
                Self.chord(.half, tieBack: 1),
                Self.chord(.quarter),
            ])]),
        ])
        let plan = try RebarPlanner.rebar(region: 0 ..< 2, in: score, numerator: 4, denominator: 4)
        #expect(plan.columns.count == 2)

        // The chain's two halves are never fused into a whole: bar 1's half stays where it is, and bar 2's
        // half is cut again at the new barline (1920).
        let first = Self.content(plan, 0)
        #expect(Self.durations(first) == [.quarter, .half] + Self.aligned(480, from: 1440))
        guard case let .chord(head) = first[1], case let .chord(joint) = first[2] else {
            Issue.record("expected chords")
            return
        }
        #expect(head.notes[0].tieForward == 1)
        #expect(joint.notes[0].tieBack == 1)
        #expect(joint.notes[0].tieForward == 1)
    }

    @Test("a chord tied in from before the region keeps its tieBack on the head piece")
    func headPieceKeepsIncomingTie() throws {
        let score = Self.score([
            Measure(voices: [Voice(elements: [Self.timeSignature44, Self.chord(.whole, tieForward: 1)])]),
            Measure(voices: [Voice(elements: [Self.chord(.whole, tieBack: 1)])]),
        ])
        let plan = try RebarPlanner.rebar(region: 0 ..< 2, in: score, numerator: 3, denominator: 4)
        // Bar 2's whole note starts at 1920, inside column 1 (1440..<2880); its first piece is the head of
        // that chord's new chain and must still be tied back to bar 1.
        let column1 = Self.content(plan, 1)
        guard case let .chord(head) = column1[1] else {
            Issue.record("expected a chord at the head of bar 2's share")
            return
        }
        #expect(head.notes[0].tieBack == 1)
        #expect(head.notes[0].tieForward == 1)
    }

    @Test("a split chord keeps its decorations on the head and its after-graces on the tail")
    func splitChordKeepsDecorations() throws {
        let grace = GraceChord(graceType: .grace16after, duration: .sixteenth, notes: [Self.note(74)])
        var decorated = Chord(duration: .whole, notes: [Self.note()])
        decorated.lyrics = [Lyric(text: "ah")]
        decorated.graceNotesAfter = [grace]
        let score = Self.score([
            Measure(voices: [Voice(elements: [Self.timeSignature44, .chord(decorated)])]),
            Measure(voices: [Voice(elements: [Self.chord(.whole)])]),
        ])
        let plan = try RebarPlanner.rebar(region: 0 ..< 2, in: score, numerator: 3, denominator: 4)
        // The whole note is cut at 1440 and again nowhere else: two pieces, in columns 0 and 1.
        guard case let .chord(head) = Self.content(plan, 0)[0],
              case let .chord(tail) = Self.content(plan, 1)[0]
        else {
            Issue.record("expected chords at both ends of the chain")
            return
        }
        #expect(head.lyrics.map(\.text) == ["ah"])
        #expect(head.graceNotesAfter.isEmpty)
        #expect(tail.graceNotesAfter == [grace])
    }

    // MARK: - Rests

    @Test("an all-rest region re-bars to measure rests in every column")
    func restPromotion() throws {
        let score = Self.score([
            Measure(voices: [Voice(elements: [Self.timeSignature44, .rest(duration: .measure)])]),
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
        ])
        let plan = try RebarPlanner.rebar(region: 0 ..< 2, in: score, numerator: 2, denominator: 4)
        #expect(plan.columns.count == 4)
        for column in plan.columns.indices {
            #expect(Self.content(plan, column) == [.rest(duration: .measure)])
        }
    }

    // MARK: - Tuplets

    @Test("a tuplet that fits inside a new bar survives with re-based indices")
    func tupletSurvivesInsideNewBar() throws {
        let triplet = VoiceElement.rest(
            duration: .fraction(Fraction(numerator: 1, denominator: 12)),
        )
        let voice = Voice(
            elements: [
                Self.timeSignature44,
                triplet, triplet, triplet,
                Self.chord(.quarter), Self.chord(.quarter), Self.chord(.quarter),
            ],
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3)],
        )
        let plan = try RebarPlanner.rebar(
            region: 0 ..< 1, in: Self.score([Measure(voices: [voice])]),
            numerator: 2, denominator: 4,
        )
        #expect(plan.columns.count == 2)
        let rebuilt = Self.voice0(plan, 0)
        #expect(rebuilt.tuplets.count == 1)
        // Column 0 opens with the new meter, so the members sit at 1...3 again.
        #expect(rebuilt.tuplets[0].startIndex == 1)
        #expect(rebuilt.tuplets[0].endIndex == 3)
        #expect(rebuilt.tuplets[0].actualNotes == 3)
        #expect(Self.voice0(plan, 1).tuplets.isEmpty)
    }

    @Test("a tuplet the new barring would straddle is refused")
    func tupletStraddleRefused() {
        let triplet = VoiceElement.rest(
            duration: .fraction(Fraction(numerator: 1, denominator: 12)),
        )
        let voice = Voice(
            elements: [
                Self.timeSignature44,
                Self.chord(.quarter),
                triplet, triplet, triplet,
                Self.chord(.quarter), Self.chord(.quarter),
            ],
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 4)],
        )
        let score = Self.score([Measure(voices: [voice])])
        // 3/8 bars fall at 720; the triplet spans 480..<960.
        let reason = Self.refusalReason {
            _ = try RebarPlanner.rebar(region: 0 ..< 1, in: score, numerator: 3, denominator: 8)
        }
        #expect(reason == .rebarWouldSplitTuplet(measureIndex: 0))
    }

    // MARK: - Irregular measures

    @Test("an actualLength pickup passes through verbatim and splits the region")
    func pickupPreserved() throws {
        let pickup = Measure(
            voices: [Voice(elements: [Self.timeSignature44, .rest(duration: .measure)])],
            actualLength: Fraction(numerator: 1, denominator: 4),
            irregular: true,
        )
        let score = Self.score([
            pickup,
            Measure(voices: [Voice(elements: [Self.chord(.whole)])]),
            Measure(voices: [Voice(elements: [Self.chord(.whole)])]),
        ])
        let plan = try RebarPlanner.rebar(region: 0 ..< 3, in: score, numerator: 3, denominator: 4)
        #expect(plan.columns.count == 4)
        #expect(plan.columns[0].staffMeasures[0][0] == pickup)
        // The new meter goes on the first REGULAR column, not on the pickup.
        #expect(Self.voice0(plan, 1).elements.first == .timeSignature(
            TimeSignature(numerator: 3, denominator: 4),
        ))
    }

    // MARK: - Carried untimed elements

    @Test("a mid-region key change and clef land at their own tick")
    func midRegionSignaturesCarried() throws {
        let score = Self.score([
            Measure(voices: [Voice(elements: [Self.timeSignature44, Self.chord(.whole)])]),
            Measure(voices: [Voice(elements: [
                .keySignature(KeySignature(concertKey: 2)),
                .clef(Clef(concertClefType: "F")),
                Self.chord(.whole),
            ])]),
        ])
        // 2/4 columns fall at 960; bar 2 starts at 1920, exactly the head of column 2.
        let plan = try RebarPlanner.rebar(region: 0 ..< 2, in: score, numerator: 2, denominator: 4)
        #expect(plan.columns.count == 4)
        let head = Self.voice0(plan, 2).elements
        #expect(head[0] == .keySignature(KeySignature(concertKey: 2)))
        #expect(head[1] == .clef(Clef(concertClefType: "F")))
    }

    // MARK: - Extra voices

    @Test("a second voice present in one bar only leaves no phantom rests later")
    func secondVoiceGap() throws {
        let upper = Voice(elements: [Self.timeSignature44, Self.chord(.whole)])
        let lower = Voice(elements: (0 ..< 4).map { _ in Self.chord(.quarter, pitch: 55) })
        let score = Self.score([
            Measure(voices: [upper, lower]),
            Measure(voices: [Voice(elements: [Self.chord(.whole)])]),
        ])
        let plan = try RebarPlanner.rebar(region: 0 ..< 2, in: score, numerator: 3, denominator: 4)
        #expect(plan.columns.count == 3)

        let first = plan.columns[0].staffMeasures[0][0]
        #expect(first.voices.count == 2)
        #expect(first.voices[1].elements.count == 3)

        let second = plan.columns[1].staffMeasures[0][0]
        #expect(second.voices.count == 2)
        #expect(second.voices[1].elements.count == 1)

        #expect(plan.columns[2].staffMeasures[0][0].voices.count == 1)
    }

    // MARK: - Location shifts

    /// The shape a `<location>` pair takes in essentially every imported MuseScore file: a displaced
    /// untimed element is jogged out to its own tick and straight back, so the voice cursor never moves.
    @Test("a jog-out/jog-back pair around a dynamic leaves the voice cursor where it was")
    func untimedJogPairKeepsTheCursor() throws {
        let dynamic = VoiceElement.dynamic(Dynamic(subtype: "f", velocity: 96))
        let score = Self.score([
            Measure(voices: [Voice(elements: [
                Self.timeSignature44,
                Self.chord(.quarter, pitch: 60),
                Self.jog(1, 4),
                dynamic,
                Self.jog(-1, 4),
                Self.chord(.quarter, pitch: 62),
                Self.chord(.quarter, pitch: 64),
                Self.chord(.quarter, pitch: 65),
            ])]),
        ])
        let plan = try RebarPlanner.rebar(region: 0 ..< 1, in: score, numerator: 3, denominator: 4)
        #expect(plan.columns.count == 2)

        // The dynamic is anchored at tick 960 while the cursor sits at 480, so it is written as +1/4, the
        // dynamic, -1/4 — and the quarter that follows still starts at 480, its own tick.
        #expect(Self.content(plan, 0) == [
            Self.chord(.quarter, pitch: 60),
            Self.jog(1, 4),
            dynamic,
            Self.jog(-1, 4),
            Self.chord(.quarter, pitch: 62),
            Self.chord(.quarter, pitch: 64),
        ])
        // Three quarters fill the 3/4 column exactly: the jog invented no rests and swallowed no time.
        #expect(Self.durations(Self.content(plan, 0)) == [.quarter, .quarter, .quarter])
        #expect(Self.content(plan, 1)
            == [Self.chord(.quarter, pitch: 65)] + Self.alignedRests(960, from: 480))
    }

    @Test("a leading gap in a higher voice survives re-barring as a locationShift")
    func higherVoiceLeadingShiftPreserved() throws {
        let upper = Voice(elements: [Self.timeSignature44, Self.chord(.whole)])
        // Voice 2 enters a quarter late: MuseScore spells that lead-in as a `<location>`, not as a rest.
        let lower = Voice(elements: [Self.jog(1, 4), Self.chord(.half, pitch: 55)])
        let score = Self.score([Measure(voices: [upper, lower])])
        let plan = try RebarPlanner.rebar(region: 0 ..< 1, in: score, numerator: 3, denominator: 4)
        #expect(plan.columns.count == 2)

        let first = plan.columns[0].staffMeasures[0][0]
        #expect(first.voices.count == 2)
        #expect(first.voices[1].elements == [Self.jog(1, 4), Self.chord(.half, pitch: 55)])
        #expect(!first.voices[1].elements.contains { $0.isRest })
        // The voice stops before the new barline; its trailing gap stays a gap rather than becoming rests.
        #expect(plan.columns[1].staffMeasures[0][0].voices.count == 1)
    }

    /// Ruling 5: a FORWARD gap in voice 0 is re-emitted as rests, not as a `.locationShift`. The main voice
    /// owns the bar's tick budget, so a hole in it is silence that has to be written — MuseScore parity.
    /// Every other gap (a higher voice, or any backwards jog) keeps its shift; see the two tests above.
    @Test("a forward gap in voice 0 materializes as rests, not as a locationShift")
    func voiceZeroGapMaterializesAsRests() throws {
        let score = Self.score([
            Measure(voices: [Voice(elements: [
                Self.timeSignature44,
                Self.chord(.quarter, pitch: 60),
                Self.jog(1, 2),
                Self.chord(.quarter, pitch: 62),
            ])]),
        ])
        // 2/4 columns fall at 960; the second chord sits at 1440, half a bar past the first one's end.
        let plan = try RebarPlanner.rebar(region: 0 ..< 1, in: score, numerator: 2, denominator: 4)
        #expect(plan.columns.count == 2)

        #expect(Self.content(plan, 0)
            == [Self.chord(.quarter, pitch: 60)] + Self.alignedRests(480, from: 480))
        #expect(Self.content(plan, 1)
            == Self.alignedRests(480, from: 0) + [Self.chord(.quarter, pitch: 62)])
        for column in plan.columns.indices {
            #expect(Self.shifts(Self.voice0(plan, column).elements).isEmpty)
        }
    }

    // MARK: - System lane

    @Test("a mid-region tempo re-homes into the column that holds its tick")
    func systemElementRehomed() throws {
        let tempo = PositionedSystemElement(
            position: MeasurePosition(numerator: 1, denominator: 4),
            element: .tempo(Tempo(beatsPerSecond: 2.0)),
        )
        let score = Self.score(
            [
                Measure(voices: [Voice(elements: [Self.timeSignature44, Self.chord(.whole)])]),
                Measure(voices: [Voice(elements: [Self.chord(.whole)])]),
            ],
            systemMeasures: [SystemMeasure(), SystemMeasure(elements: [tempo])],
        )
        let plan = try RebarPlanner.rebar(region: 0 ..< 2, in: score, numerator: 3, denominator: 4)
        // Absolute tick 1920 + 480 = 2400; column 1 spans 1440..<2880, so the offset is 960 ticks = 1/2.
        #expect(plan.columns[0].systemMeasure.elements.isEmpty)
        #expect(plan.columns[1].systemMeasure.elements.count == 1)
        #expect(plan.columns[1].systemMeasure.elements[0].position
            == MeasurePosition(numerator: 1, denominator: 2))
        #expect(plan.columns[1].systemMeasure.elements[0].element == tempo.element)
        #expect(plan.columns[2].systemMeasure.elements.isEmpty)
    }

    // MARK: - Barline markers

    @Test("a startRepeat that stays on a new boundary re-homes onto it")
    func startRepeatSurvivesOnBoundary() throws {
        let score = Self.score([
            Measure(voices: [Voice(elements: [Self.timeSignature44, Self.chord(.whole)])]),
            Measure(voices: [Voice(elements: [Self.chord(.whole)])], startRepeat: true),
        ])
        let plan = try RebarPlanner.rebar(region: 0 ..< 2, in: score, numerator: 2, denominator: 4)
        #expect(plan.columns.count == 4)
        #expect(plan.columns.map { $0.staffMeasures[0][0].startRepeat } == [false, false, true, false])
    }

    @Test("a startRepeat the new barring would displace is refused")
    func startRepeatDisplacedRefused() {
        let score = Self.score([
            Measure(voices: [Voice(elements: [Self.timeSignature44, Self.chord(.whole)])]),
            Measure(voices: [Voice(elements: [Self.chord(.whole)])], startRepeat: true),
        ])
        let reason = Self.refusalReason {
            _ = try RebarPlanner.rebar(region: 0 ..< 2, in: score, numerator: 3, denominator: 4)
        }
        #expect(reason == .rebarWouldDisplaceBarlineMarker(measureIndex: 1))
    }
}
