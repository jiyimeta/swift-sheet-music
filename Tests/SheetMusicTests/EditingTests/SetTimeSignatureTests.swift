@testable import SheetMusicCore
import Testing

/// `.setTimeSignature` / `.removeTimeSignature` — the two meter intents, driven through `ScoreEditSession` so the
/// re-barring `RebarPlanner` plans and the glyph repairs the session bundles on top are both part of what every
/// assertion sees.
///
/// Every split expectation is computed with `DurationChangeAlgorithm.alignedDurations` rather than hand-guessed, the
/// same rule `RebarPlannerTests` follows: a change to the beat-alignment rule then moves the planner and these tests
/// together instead of leaving a frozen number behind.
@Suite("Time signature intents")
struct SetTimeSignatureTests {
    private static let division = 480
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    // MARK: - Fixtures

    /// Piano (two staves) + B♭ clarinet, 4 bars of 4/4, a whole-note C in every bar of every staff.
    ///
    /// Bar 0 opens on the key and time signature, so its measure rest sits at element 2; every later bar holds the
    /// rest alone. The pitch is a plain C (tpc 14) so no accidental glyph is in play — the renotation composition
    /// has its own test, and everywhere else it must stay out of the way of a byte-for-byte round trip.
    private func uniform44() -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [
                .init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G"), .init(clefType: "F")]),
                .init(
                    instrumentID: "clarinet-bb", longName: "Clarinet",
                    staves: [.init(clefType: "G")], transposeDiatonic: -1, transposeChromatic: -2,
                ),
            ],
            concertKey: 0, measureCount: 4,
        ))
        for (partIndex, part) in score.parts.enumerated() {
            for staffIndex in part.staves.indices {
                for measure in 0 ..< 4 {
                    let slot = measure == 0 ? 2 : 0
                    score.parts[partIndex].staves[staffIndex].measures[measure].voices[0].elements[slot] =
                        .chord(Chord(duration: .whole, notes: [Note(pitch: 72, tpc: 14)]))
                }
            }
        }
        return score
    }

    /// `uniform44()`'s shape with an explicit 3/4 at bar 2: bars 0–1 hold their whole notes, bars 2–3 keep the
    /// measure rest that 3/4 now sizes at three quarters.
    private func changeAtBarTwo() -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [
                .init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G"), .init(clefType: "F")]),
                .init(instrumentID: "clarinet-bb", longName: "Clarinet", staves: [.init(clefType: "G")]),
            ],
            concertKey: 0, measureCount: 4,
        ))
        for (partIndex, part) in score.parts.enumerated() {
            for staffIndex in part.staves.indices {
                for measure in 0 ..< 2 {
                    let slot = measure == 0 ? 2 : 0
                    score.parts[partIndex].staves[staffIndex].measures[measure].voices[0].elements[slot] =
                        .chord(Chord(duration: .whole, notes: [Note(pitch: 72, tpc: 14)]))
                }
                score.parts[partIndex].staves[staffIndex].measures[2].voices[0].elements
                    .insert(.timeSignature(TimeSignature(numerator: 3, denominator: 4)), at: 0)
            }
        }
        return score
    }

    // MARK: - Readers

    private static func voice0(_ score: Score, _ part: Int, _ staff: Int, _ measure: Int) -> Voice {
        score.parts[part].staves[staff].measures[measure].voices[0]
    }

    /// One bar's voice 0 with the leading signature run stripped — the timed content alone.
    private static func content(_ score: Score, _ part: Int, _ staff: Int, _ measure: Int) -> [VoiceElement] {
        Array(voice0(score, part, staff, measure).elements.drop(while: MeasureStructure.isLeadingSignature))
    }

    private static func durations(_ elements: [VoiceElement]) -> [NoteDuration] {
        elements.compactMap { if case let .chord(chord) = $0 { chord.duration } else { nil } }
    }

    private static func aligned(_ ticks: Int, from rtickStart: Int) -> [NoteDuration] {
        DurationChangeAlgorithm.alignedDurations(forTicks: ticks, rtickStart: rtickStart, division: division)
    }

    /// The time signature `measure` declares on `part`/`staff`, wherever in the bar it sits.
    private static func declared(_ score: Score, _ part: Int, _ staff: Int, _ measure: Int) -> TimeSignature? {
        for voice in score.parts[part].staves[staff].measures[measure].voices {
            for element in voice.elements {
                if case let .timeSignature(signature) = element { return signature }
            }
        }
        return nil
    }

    private static func measureCounts(_ score: Score) -> [Int] {
        score.parts.flatMap { $0.staves.map(\.measures.count) }
    }

    private static func spannerOffset(_ score: Score, at id: VoiceElementID) -> Int? {
        guard case let .spanner(spanner) = score[id] else { return nil }
        return spanner.nextMeasuresOffset
    }

    // MARK: - .setTimeSignature

    @Test("4/4 to 3/4 at bar 0 re-bars the whole score, and every staff agrees on the new bar count")
    func setAtZeroRebarsWholeScoreAndCountsChange() {
        let session = ScoreEditSession(score: uniform44())
        #expect(session.apply(.setTimeSignature(measureIndex: 0, numerator: 3, denominator: 4)))
        let score = session.score

        // 4 bars x 1920 ticks = 7680; at 1440 ticks a bar that is six columns, the last one padded.
        #expect(Self.measureCounts(score) == [6, 6, 6])
        #expect(score.systemMeasures.count == 6)
        for (partIndex, part) in score.parts.enumerated() {
            for staffIndex in part.staves.indices {
                #expect(Self.declared(score, partIndex, staffIndex, 0)
                    == TimeSignature(numerator: 3, denominator: 4))
                // Exactly one declaration in the whole re-barred region.
                let declarations = (0 ..< 6).compactMap { Self.declared(score, partIndex, staffIndex, $0) }
                #expect(declarations.count == 1)

                // Bar 1's whole note is cut at 1440, bar 2's at 2880, bar 3's at 4320 — one chain each, tied.
                #expect(Self.durations(Self.content(score, partIndex, staffIndex, 0)) == Self.aligned(1440, from: 0))
                #expect(Self.durations(Self.content(score, partIndex, staffIndex, 1))
                    == Self.aligned(480, from: 0) + Self.aligned(960, from: 480))
                #expect(Self.durations(Self.content(score, partIndex, staffIndex, 2))
                    == Self.aligned(960, from: 0) + Self.aligned(480, from: 960))
                #expect(Self.durations(Self.content(score, partIndex, staffIndex, 3)) == Self.aligned(1440, from: 0))
            }
        }
        // The cut is a tie, not two loose notes.
        guard case let .chord(head) = Self.content(score, 0, 0, 0).last,
              case let .chord(tail) = Self.content(score, 0, 0, 1).first
        else { Issue.record("expected chords either side of the new barline"); return }
        #expect(head.notes[0].tieForward == 1)
        #expect(tail.notes[0].tieBack == 1)
    }

    @Test("a mid-piece change re-bars only its own span and leaves the bars before it byte-identical")
    func setMidPieceRebarsOnlyThatSpan() {
        let original = changeAtBarTwo()
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 2, numerator: 2, denominator: 4)))
        let score = session.score

        // Bars 2–3 are 3/4 (1440 ticks each); 2880 ticks re-bar into three 960-tick columns.
        #expect(Self.measureCounts(score) == [5, 5, 5])
        for (partIndex, part) in score.parts.enumerated() {
            for staffIndex in part.staves.indices {
                for measure in 0 ..< 2 {
                    #expect(score.parts[partIndex].staves[staffIndex].measures[measure]
                        == original.parts[partIndex].staves[staffIndex].measures[measure])
                }
                #expect(Self.declared(score, partIndex, staffIndex, 2) == TimeSignature(numerator: 2, denominator: 4))
                for measure in 2 ..< 5 {
                    #expect(Self.content(score, partIndex, staffIndex, measure) == [.rest(duration: .measure)])
                }
            }
        }
        #expect(score.effectiveMeasureDurations() == [
            Fraction(numerator: 4, denominator: 4), Fraction(numerator: 4, denominator: 4),
            Fraction(numerator: 2, denominator: 4), Fraction(numerator: 2, denominator: 4),
            Fraction(numerator: 2, denominator: 4),
        ])
    }

    @Test("apply, undo, redo and undo again all round-trip byte for byte")
    func applyUndoRoundTripsByteForByte() {
        let original = uniform44()
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 0, numerator: 3, denominator: 4)))
        // Intermediate state, asserted before the undo: a symmetric bug in apply and its inverse cancels
        // invisibly in the round trip alone.
        let applied = session.score
        #expect(applied != original)
        #expect(Self.measureCounts(applied) == [6, 6, 6])

        #expect(session.undo())
        #expect(session.score == original)
        #expect(session.redo())
        #expect(session.score == applied)
        #expect(session.undo())
        #expect(session.score == original)
    }

    @Test("the whole operation is one undo step")
    func oneUndoStepOnly() {
        let original = uniform44()
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 0, numerator: 3, denominator: 4)))
        #expect(session.canUndo)
        #expect(session.undo())
        #expect(session.score == original)
        #expect(!session.canUndo)
    }

    @Test("a tuplet the new barring would straddle refuses the whole operation, score untouched")
    func tupletConflictRefusesWholeOperationScoreUntouched() {
        var original = uniform44()
        let triplet = VoiceElement.rest(duration: .fraction(Fraction(numerator: 1, denominator: 12)))
        // Bar 0: quarter, triplet (480..<960), two quarters. 3/8 columns fall at 720, inside the triplet.
        original.parts[0].staves[0].measures[0].voices[0] = Voice(
            elements: [
                .keySignature(KeySignature(concertKey: 0)),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14)])),
                triplet, triplet, triplet,
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14)])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14)])),
            ],
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 3, endIndex: 5)],
        )
        let session = ScoreEditSession(score: original)
        #expect(!session.apply(.setTimeSignature(measureIndex: 0, numerator: 3, denominator: 8)))
        #expect(session.lastRefusal?.reason == .rebarWouldSplitTuplet(measureIndex: 0))
        #expect(session.score == original)
        #expect(!session.canUndo)
    }

    @Test("setting the meter already in force resolves to nothing to apply")
    func setSamePlansToNothing() {
        let score = uniform44()
        let session = ScoreEditSession(score: score)
        #expect(!session.apply(.setTimeSignature(measureIndex: 0, numerator: 4, denominator: 4)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(session.score == score)
        #expect(!session.canUndo)
    }

    // MARK: - .removeTimeSignature

    @Test("removing a change re-bars its span back to the prevailing meter, and undo puts it back exactly")
    func removeRevertsToPrevailingAndRoundTrips() {
        let original = changeAtBarTwo()
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.removeTimeSignature(measureIndex: 2)))
        let score = session.score

        // Bars 2–3 held 2880 ticks of 3/4; back at 4/4 that is two columns, so the bar count is unchanged.
        #expect(Self.measureCounts(score) == [4, 4, 4])
        for (partIndex, part) in score.parts.enumerated() {
            for staffIndex in part.staves.indices {
                #expect(Self.declared(score, partIndex, staffIndex, 2) == nil)
                for measure in 2 ..< 4 {
                    #expect(Self.content(score, partIndex, staffIndex, measure) == [.rest(duration: .measure)])
                }
            }
        }
        #expect(score.effectiveMeasureDurations()
            == Array(repeating: Fraction(numerator: 4, denominator: 4), count: 4))
        #expect(session.undo())
        #expect(session.score == original)
    }

    @Test("the score's opening meter cannot be removed")
    func removeAtZeroRefused() {
        let score = changeAtBarTwo()
        let session = ScoreEditSession(score: score)
        #expect(!session.apply(.removeTimeSignature(measureIndex: 0)))
        #expect(session.lastRefusal?.reason == .cannotRemoveInitialSignature)
        #expect(session.score == score)
        #expect(!session.canUndo)
    }

    @Test("removing where no explicit change exists resolves to nothing to apply")
    func removeWhereNoChangePlansToNothing() {
        let score = changeAtBarTwo()
        let session = ScoreEditSession(score: score)
        #expect(!session.apply(.removeTimeSignature(measureIndex: 1)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(session.score == score)
        #expect(!session.canUndo)
    }

    // MARK: - Spanners crossing the region

    /// A spanner stores a MEASURE distance, so a re-bar that changes how many bars its span covers has to restate
    /// it — otherwise a hairpin drawn to bar 3 silently ends somewhere else.
    @Test("a spanner anchored before the region keeps its endpoint's tick across a re-bar")
    func spannerAcrossRegionKeepsItsEndpoints() {
        var original = uniform44()
        original.parts[0].staves[0].measures[0].voices[0].elements.append(.spanner(Spanner(
            kind: .hairpin, rawType: "HairPin", nextMeasuresOffset: 3,
        )))
        let anchor = VoiceElementID(
            staff: Self.staff0, measureIndex: 0, voiceIndex: 0,
            elementIndex: original.parts[0].staves[0].measures[0].voices[0].elements.count - 1,
        )
        #expect(Self.spannerOffset(original, at: anchor) == 3)

        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 2, denominator: 4)))
        // Region [1, 4): 5760 ticks at 960 a bar is six columns, so the score grows 4 bars → 7. The old bar 3
        // started at tick 5760, which is now the head of bar 5 (1920 + 4 x 960).
        #expect(Self.measureCounts(session.score) == [7, 7, 7])
        #expect(Self.spannerOffset(session.score, at: anchor) == 5)
        #expect(session.undo())
        #expect(session.score == original)
        #expect(Self.spannerOffset(session.score, at: anchor) == 3)
    }

    // MARK: - Session interplay

    /// The session's diff-driven `renotatingAccidentals` pass sees every re-barred bar as changed, so a note that
    /// crosses a new barline is re-judged in the bar it lands in — and gets the glyph that bar needs.
    @Test("a re-bar that moves an accidental-carrying note into a new bar re-spells its glyph")
    func rebarRenotatesMovedAccidentals() {
        var original = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")])],
            concertKey: 0, measureCount: 1,
        ))
        original.parts[0].staves[0].measures[0].voices[0].elements = [
            .keySignature(KeySignature(concertKey: 0)),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 61, tpc: 21, accidental: .sharp)])),
            // The second C♯ needs no glyph while it shares a bar with the first one.
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 61, tpc: 21)])),
            .rest(duration: .half),
        ]
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 0, numerator: 1, denominator: 4)))
        // 1920 ticks at 480 a bar: the two quarters end up in bars 0 and 1, so the second one is now the first
        // C♯ of its own bar and has to say so.
        #expect(Self.measureCounts(session.score) == [4])
        guard case let .chord(moved) = Self.content(session.score, 0, 0, 1).first else {
            Issue.record("expected the second C♯ to land in bar 1"); return
        }
        #expect(moved.notes[0].accidental == .sharp)
        #expect(session.undo())
        #expect(session.score == original)
    }

    // MARK: - Irregular bars at the region head

    /// A pickup is passed through verbatim by `RebarPlanner` — its length is its own, not the meter's — so the
    /// explicit signature it already carries is the one this command has to restate.
    @Test("a pickup at the region head has its own signature value-replaced, keeping its length")
    func pickupHeadKeepsItsExplicitSignatureValueReplaced() {
        var original = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")])],
            concertKey: 0, measureCount: 3,
        ))
        original.parts[0].staves[0].measures[0].actualLength = Fraction(numerator: 1, denominator: 4)
        original.parts[0].staves[0].measures[0].irregular = true
        // A courtesy-suppressed opening signature: this intent states which meter, never how it is drawn, so the
        // replacement has to be a value edit of the element already there rather than a fresh one.
        original.parts[0].staves[0].measures[0].voices[0].elements[1] =
            .timeSignature(TimeSignature(numerator: 4, denominator: 4, showCourtesy: false))
        for measure in 1 ..< 3 {
            original.parts[0].staves[0].measures[measure].voices[0].elements[0] =
                .chord(Chord(duration: .whole, notes: [Note(pitch: 72, tpc: 14)]))
        }
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 0, numerator: 3, denominator: 4)))
        let score = session.score

        #expect(score.parts[0].staves[0].measures[0].actualLength == Fraction(numerator: 1, denominator: 4))
        #expect(score.parts[0].staves[0].measures[0].irregular)
        #expect(Self.declared(score, 0, 0, 0)
            == TimeSignature(numerator: 3, denominator: 4, showCourtesy: false))
        // The pickup's content is untouched, and the two 4/4 bars behind it re-bar into three 3/4 ones.
        #expect(Self.content(score, 0, 0, 0) == [.rest(duration: .measure)])
        #expect(Self.measureCounts(score) == [4])
        #expect(score.effectiveMeasureDurations() == [
            Fraction(numerator: 1, denominator: 4), Fraction(numerator: 3, denominator: 4),
            Fraction(numerator: 3, denominator: 4), Fraction(numerator: 3, denominator: 4),
        ])
        // One declaration for the region, at its head — the pickup already says it, so no bar restates it.
        #expect((0 ..< 4).compactMap { Self.declared(score, 0, 0, $0) }.count == 1)
        #expect(session.undo())
        #expect(session.score == original)
    }

    /// The degenerate end of the same rule: when EVERY bar of the region is irregular, `RebarPlanner` emits no
    /// leading signature anywhere, so a head that declares nothing has to have one inserted or the edit would
    /// change nothing at all.
    @Test("an all-irregular region gets the signature inserted at its head, after the clef and key")
    func allIrregularRegionGetsAnInsertedSignatureAtTheHead() {
        var original = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")])],
            concertKey: 0, measureCount: 2,
        ))
        for measure in 0 ..< 2 {
            original.parts[0].staves[0].measures[measure].voices[0] = Voice(
                elements: [
                    .clef(Clef(concertClefType: "G")),
                    .keySignature(KeySignature(concertKey: 0)),
                    .rest(duration: .measure),
                ],
                tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 2)],
            )
            original.parts[0].staves[0].measures[measure].actualLength = Fraction(numerator: 1, denominator: 4)
            original.parts[0].staves[0].measures[measure].irregular = true
        }
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 0, numerator: 3, denominator: 4)))
        let voice = Self.voice0(session.score, 0, 0, 0)

        guard case .clef = voice.elements[0] else { Issue.record("the clef must stay first"); return }
        guard case .keySignature = voice.elements[1] else { Issue.record("the key follows the clef"); return }
        #expect(voice.elements[2] == .timeSignature(TimeSignature(numerator: 3, denominator: 4)))
        #expect(voice.tuplets == [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 3, endIndex: 3)])
        #expect(Self.measureCounts(session.score) == [2])
        #expect(session.score.parts[0].staves[0].measures[0].actualLength
            == Fraction(numerator: 1, denominator: 4))
        #expect(Self.declared(session.score, 0, 0, 1) == nil)
        #expect(session.undo())
        #expect(session.score == original)
    }
}
