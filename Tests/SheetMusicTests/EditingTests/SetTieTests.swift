@testable import SheetMusicCore
import Testing

@Suite("RemoveTie")
struct RemoveTieTests {
    private static func note(_ index: Int) -> NoteID {
        NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: index,
            noteIndexInChord: 0,
        )
    }

    private static func fixture(forward: Int? = 7, back: Int? = 7) -> Score {
        var first = Note(pitch: 60, tpc: 14)
        first.tieBack = 5
        first.tieForward = forward
        var second = Note(pitch: 60, tpc: 14)
        second.tieBack = back
        second.tieForward = 9
        var third = Note(pitch: 60, tpc: 14)
        third.tieBack = 9
        let voice = Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [first])),
            .chord(Chord(duration: .quarter, notes: [second])),
            .chord(Chord(duration: .quarter, notes: [third])),
        ])
        return ScoreEditor(score: Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "x"),
            staves: [Staff(measures: [Measure(voices: [voice])])],
        )])).score
    }

    @Test("clears only the matching pair and restores it exactly")
    func removesAndRestoresLinks() throws {
        var score = Self.fixture()
        let before = score
        let command = RemoveTie(start: Self.note(0), end: Self.note(1))
        #expect(command.affectedLocation == VoiceElementID(Self.note(0)))
        let inverse = try command.apply(to: &score)
        #expect(score[Self.note(0)]?.tieForward == nil)
        #expect(score[Self.note(1)]?.tieBack == nil)
        #expect(score[Self.note(0)]?.tieBack == 5)
        #expect(score[Self.note(1)]?.tieForward == 9)
        #expect(score[Self.note(2)]?.tieBack == 9)
        #expect(score.stableFingerprint != before.stableFingerprint)
        var expected = before
        _ = try SetTie(from: Self.note(0), to: Self.note(1), sourceTieForward: nil, targetTieBack: nil)
            .apply(to: &expected)
        #expect(score == expected)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
        #expect(score.stableFingerprint == before.stableFingerprint)
    }

    @Test("absent, half-present and mismatched links are refused", arguments: [0, 1, 2, 3])
    func unrelatedLinks(_ variant: Int) {
        let links: [(Int?, Int?)] = [(nil, nil), (7, nil), (nil, 7), (7, 8)]
        var score = Self.fixture(forward: links[variant].0, back: links[variant].1)
        let before = score
        let error = #expect(throws: SheetMusicError.self) {
            _ = try RemoveTie(start: Self.note(0), end: Self.note(1)).apply(to: &score)
        }
        guard case let .invalidEdit(refusal)? = error else { Issue.record("expected refusal"); return }
        #expect(refusal.reason == .noTieBetween(start: Self.note(0), end: Self.note(1)))
        #expect(refusal.operation == "RemoveTie")
        #expect(refusal.code == "edit.noTieBetween")
        #expect(refusal.developerDescription == "RemoveTie: no tie between \(Self.note(0)) and \(Self.note(1))")
        #expect(score == before)
        #expect(score.stableFingerprint == before.stableFingerprint)
    }

    @Test("a stale A-to-B address now naming X and A cannot cut Z-to-A")
    func staleSelectionPreservesIncomingTie() {
        let voice = Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14, tieForward: 5)])), // Z
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14, tieForward: 7, tieBack: 5)])), // A
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14, tieBack: 7)])), // B
        ])
        var literal = Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [Measure(voices: [voice])])],
        )])
        let stale = RemoveTie(start: Self.note(1), end: Self.note(2))
        literal.parts[0].staves[0].measures[0].voices[0].elements.insert(
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])), at: 1, // X
        )
        var score = ScoreEditor(score: literal).score
        let before = score
        let error = #expect(throws: SheetMusicError.self) { _ = try stale.apply(to: &score) }
        guard case let .invalidEdit(refusal)? = error else { Issue.record("expected refusal"); return }
        #expect(refusal.reason == .noTieBetween(start: Self.note(1), end: Self.note(2)))
        #expect(refusal.operation == "RemoveTie")
        #expect(score[Self.note(0)]?.tieForward == 5)
        #expect(score[Self.note(2)]?.tieBack == 5)
        #expect(score[Self.note(2)]?.tieForward == 7)
        #expect(score[Self.note(3)]?.tieBack == 7)
        #expect(score == before)
        #expect(score.stableFingerprint == before.stableFingerprint)
    }

    @Test("missing source or target is refused before either write", arguments: [false, true])
    func missingNote(_ missingSource: Bool) {
        var score = Self.fixture()
        let before = score
        let missing = Self.note(3)
        let error = #expect(throws: SheetMusicError.self) {
            _ = try RemoveTie(
                start: missingSource ? missing : Self.note(0),
                end: missingSource ? Self.note(1) : missing,
            ).apply(to: &score)
        }
        guard case let .invalidEdit(refusal)? = error else { Issue.record("expected refusal"); return }
        #expect(refusal.reason == .noteNotFound(missing))
        #expect(refusal.operation == "RemoveTie")
        #expect(score == before)
        #expect(score.stableFingerprint == before.stableFingerprint)
    }
}

@Suite("SetTie")
struct SetTieTests {
    /// Build a measure with two consecutive C4 quarter chords.
    private static func twoCQuarters() -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )),
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )),
            .rest(duration: .half),
        ])
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        return Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
    }

    private static let firstC = NoteID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
        voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
    )
    private static let secondC = NoteID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
        voiceIndex: 0, elementIndex: 2, noteIndexInChord: 0,
    )

    @Test("apply sets tieForward and tieBack")
    func applyAddsTie() throws {
        var score = ScoreEditor(score: Self.twoCQuarters()).score
        let cmd = SetTie(
            from: Self.firstC, to: Self.secondC,
            sourceTieForward: 1, targetTieBack: 1,
        )
        _ = try cmd.apply(to: &score)
        #expect(score[Self.firstC]?.tieForward == 1)
        #expect(score[Self.secondC]?.tieBack == 1)
    }

    @Test("inverse removes the tie")
    func inverseRemovesTie() throws {
        var score = ScoreEditor(score: Self.twoCQuarters()).score
        let original = score
        let cmd = SetTie(
            from: Self.firstC, to: Self.secondC,
            sourceTieForward: 1, targetTieBack: 1,
        )
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("clear-then-set round-trips through inverse")
    func clearThenSetRoundTrips() throws {
        var score = ScoreEditor(score: Self.twoCQuarters()).score
        // Pre-tie the notes manually.
        let pre = SetTie(
            from: Self.firstC, to: Self.secondC,
            sourceTieForward: 1, targetTieBack: 1,
        )
        _ = try pre.apply(to: &score)
        let snapshot = score
        // Now clear via SetTie(...nil).
        let clear = SetTie(
            from: Self.firstC, to: Self.secondC,
            sourceTieForward: nil, targetTieBack: nil,
        )
        let inverse = try clear.apply(to: &score)
        #expect(score[Self.firstC]?.tieForward == nil)
        #expect(score[Self.secondC]?.tieBack == nil)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }
}

@Suite("Score.nextTieTarget")
struct ScoreNextTieTargetTests {
    @Test("returns adjacent same-pitch chord")
    func adjacentSamePitch() {
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )),
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )),
        ])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1", instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: [voice])])],
            )],
        )
        let source = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
            noteIndexInChord: 0,
        )
        let target = ScoreEditor(score: score).score.nextTieTarget(after: source)
        #expect(target?.elementIndex == 1)
        #expect(target?.noteIndexInChord == 0)
    }

    @Test("returns nil when next chord has different pitch")
    func differentPitch() {
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )),
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 62, tpc: 16)],
            )),
        ])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1", instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: [voice])])],
            )],
        )
        let source = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
            noteIndexInChord: 0,
        )
        #expect(ScoreEditor(score: score).score.nextTieTarget(after: source) == nil)
    }

    @Test("returns nil when a rest separates the chords")
    func restBetween() {
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )),
            .rest(duration: .quarter),
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )),
        ])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1", instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: [voice])])],
            )],
        )
        let source = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
            noteIndexInChord: 0,
        )
        #expect(ScoreEditor(score: score).score.nextTieTarget(after: source) == nil)
    }

    @Test("skips non-timed elements (clef / barline)")
    func skipsNonTimedElements() {
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )),
            .barLine(BarLine()),
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )),
        ])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1", instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: [voice])])],
            )],
        )
        let source = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
            noteIndexInChord: 0,
        )
        let target = ScoreEditor(score: score).score.nextTieTarget(after: source)
        #expect(target?.elementIndex == 2)
    }
}
