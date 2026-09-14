@testable import SheetMusicCore
import Testing

@Suite("TransposeScore")
struct TransposeScoreTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int, measure: Int = 0, staff: StaffAddress = staff0) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func chord(_ pitch: Int, _ tpc: Int, _ duration: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: tpc)]))
    }

    private static func note(_ score: Score, _ element: Int, measure: Int = 0) -> Note? {
        guard case let .chord(chord)? = score[slot(element, measure: measure)] else { return nil }
        return chord.notes.first
    }

    private static func declaredKey(_ score: Score, measure: Int) -> Int? {
        KeySignatureStaves.explicitKey(in: score, staff: staff0, measureIndex: measure)?.concertKey
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    /// Two 4/4 bars in C major, the key left UNDECLARED the way MuseScore leaves it: `[ts, C4 q, E4 q, G4 q, r]`
    /// then `[C5 q, r, r, r]`.
    private static func cMajorUndeclared() -> Score {
        let first = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            chord(60, 14), chord(64, 18), chord(67, 15), .rest(duration: .quarter),
        ])
        let second = Voice(elements: [
            chord(72, 14), .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        let staff = Staff(measures: [Measure(voices: [first]), Measure(voices: [second])])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
        return Score(division: 480, parts: [part])
    }

    // MARK: - The key arithmetic

    @Test("a key moves seven fifths per semitone, read back into −7…+7 with the fewer accidentals")
    func keyArithmetic() {
        #expect(TranspositionPlanner.key(0, transposedBy: 2) == 2) // C → D
        #expect(TranspositionPlanner.key(0, transposedBy: 1) == -5) // C → D♭, not C♯ (5 flats beat 7 sharps)
        #expect(TranspositionPlanner.key(0, transposedBy: -1) == 5) // C → B, not C♭
        #expect(TranspositionPlanner.key(-2, transposedBy: 2) == 0) // B♭ → C
        #expect(TranspositionPlanner.key(3, transposedBy: 1) == -2) // A → B♭
        #expect(TranspositionPlanner.key(0, transposedBy: 12) == 0) // an octave changes no key
        #expect(TranspositionPlanner.key(4, transposedBy: -5) == 5) // E → B
    }

    @Test("the tritone is the one genuine tie, and the direction of travel breaks it")
    func tritoneFollowsDirection() {
        #expect(TranspositionPlanner.key(0, transposedBy: 6) == 6) // up → F♯
        #expect(TranspositionPlanner.key(0, transposedBy: -6) == -6) // down → G♭
    }

    // MARK: - The whole-score move

    @Test("every note moves and bar 1 gains the key it is now in, though it declared none before")
    func notesAndKeyMoveTogether() throws {
        var score = Self.cMajorUndeclared()
        #expect(Self.declaredKey(score, measure: 0) == nil)
        _ = try TransposeScore(semitones: 2, transposeKeySignatures: true).apply(to: &score)
        #expect(Self.declaredKey(score, measure: 0) == 2) // D major
        // Bar 0's elements shifted by one: the key signature was INSERTED, which is why a host restoring a
        // selection across this command has to do it by column rather than by element index.
        #expect(Self.note(score, 2)?.pitch == 62) // C4 → D4
        #expect(Self.note(score, 3)?.pitch == 66) // E4 → F♯4
        #expect(Self.note(score, 3)?.tpc == 20) // spelled F♯, the reading D major asks for
        #expect(Self.note(score, 4)?.pitch == 69) // G4 → A4
        #expect(Self.note(score, 0, measure: 1)?.pitch == 74) // C5 → D5
    }

    @Test("with transposeKeySignatures off the notes move alone and the score keeps its key")
    func keysCanStayPut() throws {
        var score = Self.cMajorUndeclared()
        _ = try TransposeScore(semitones: 2, transposeKeySignatures: false).apply(to: &score)
        #expect(Self.declaredKey(score, measure: 0) == nil)
        #expect(Self.note(score, 1)?.pitch == 62)
        #expect(Self.note(score, 2)?.pitch == 66)
        #expect(Self.note(score, 2)?.accidental == .sharp) // spelled against C major, so the glyph shows
    }

    @Test("a mid-score key change moves too, keeping its distance from the new home key")
    func midScoreKeyChangeMoves() throws {
        var score = EditingFixtures.twoMeasuresOfQuarterRests(key: 0)
        score[Self.slot(2)] = Self.chord(60, 14)
        _ = try SetKeySignature(measureIndex: 1, concertKey: 3).apply(to: &score) // bar 2 modulates to A
        _ = try TransposeScore(semitones: 2, transposeKeySignatures: true).apply(to: &score)
        #expect(Self.declaredKey(score, measure: 0) == 2) // C → D
        #expect(Self.declaredKey(score, measure: 1) == 5) // A → B, two fifths further out, as before
    }

    @Test("an octave leaves every key where it was and still moves every note")
    func octaveKeepsTheKey() throws {
        var score = Self.cMajorUndeclared()
        _ = try SetKeySignature(measureIndex: 0, concertKey: -2).apply(to: &score)
        _ = try TransposeScore(semitones: 12, transposeKeySignatures: true).apply(to: &score)
        #expect(Self.declaredKey(score, measure: 0) == -2)
        #expect(Self.note(score, 2)?.pitch == 72)
    }

    @Test("a percussion staff is left alone — no pitch to move, no key to be in")
    func percussionIsSkipped() throws {
        let pitched = Self.cMajorUndeclared().parts[0]
        let kit = Staff(measures: [
            Measure(voices: [Voice(elements: [
                Self.chord(38, 14),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
            ])]),
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
        ])
        var score = Score(division: 480, parts: [
            pitched,
            Part(id: "2", instrument: Instrument(id: "drumset", useDrumset: true), staves: [kit]),
        ])
        let drumSlot = Self.slot(0, staff: StaffAddress(partIndex: 1, staffIndexInPart: 0))
        _ = try TransposeScore(semitones: 2, transposeKeySignatures: true).apply(to: &score)
        guard case let .chord(drum)? = score[drumSlot] else {
            Issue.record("the kit's chord went missing")
            return
        }
        #expect(drum.notes.first?.pitch == 38)
    }

    @Test("grace notes move with the chord that carries them")
    func graceNotesMove() throws {
        var score = Self.cMajorUndeclared()
        var carrier = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        carrier.graceNotesBefore = [GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [
            Note(pitch: 59, tpc: 19),
        ])]
        score[Self.slot(1)] = .chord(carrier)
        _ = try TransposeScore(semitones: 2, transposeKeySignatures: true).apply(to: &score)
        guard case let .chord(moved)? = score[Self.slot(2)] else {
            Issue.record("the carrier chord went missing")
            return
        }
        #expect(moved.notes.first?.pitch == 62)
        #expect(moved.graceNotesBefore.values.first?.notes.first?.pitch == 61)
    }

    // MARK: - Refusals and inertness

    @Test("a note that cannot stay inside MIDI 0…127 refuses the whole move, nothing written")
    func outOfRangeRefusesEverything() {
        var score = Self.cMajorUndeclared()
        score[Self.slot(3)] = Self.chord(126, 15)
        let before = score
        let refused = #expect(throws: SheetMusicError.self) {
            _ = try TransposeScore(semitones: 5, transposeKeySignatures: true).apply(to: &score)
        }
        #expect(Self.reason(of: refused) == .transpositionOutOfRange(at: Self.slot(3), semitones: 5))
        #expect(score == before)
    }

    @Test("more than two octaves is refused, the bound TransposeRange states")
    func twoOctaveBound() {
        var score = Self.cMajorUndeclared()
        let refused = #expect(throws: SheetMusicError.self) {
            _ = try TransposeScore(semitones: 25, transposeKeySignatures: true).apply(to: &score)
        }
        #expect(Self.reason(of: refused) == .invalidTransposition(semitones: 25))
    }

    @Test("zero semitones plans to nothing")
    func zeroIsInert() throws {
        let score = Self.cMajorUndeclared()
        #expect(try TransposeScore(semitones: 0, transposeKeySignatures: true)
            .plan(in: score, ids: EIDAllocator()) == nil)
    }

    @Test("a chord symbol is left as it was typed — the gap docs/edit-commands.md §C names")
    func chordSymbolsDoNotMove() throws {
        var score = Self.cMajorUndeclared()
        _ = try SetChordSymbol(at: Self.slot(1), name: "Cmaj7").apply(to: &score)
        _ = try TransposeScore(semitones: 2, transposeKeySignatures: true).apply(to: &score)
        let symbols = score.parts[0].staves[0].measures[0].voices[0].elements.values.compactMap { element -> String? in
            guard case let .harmony(harmony) = element else { return nil }
            return harmony.name
        }
        #expect(symbols == ["Cmaj7"])
    }

    @Test("undo restores the score exactly, key signature insertion and all")
    func undoIsExact() throws {
        var score = Self.cMajorUndeclared()
        let before = score
        let inverse = try TransposeScore(semitones: -3, transposeKeySignatures: true).apply(to: &score)
        #expect(score != before)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("the intent applies through the session as one undo step")
    func intentIsOneUndoStep() {
        let session = ScoreEditSession(score: Self.cMajorUndeclared())
        let before = session.score
        #expect(session.apply(.transposeScore(
            semitones: 2, transposeKeySignatures: true, respellInKey: true,
        )))
        #expect(session.score != before)
        #expect(session.undo())
        #expect(session.score == before)
    }

    @Test("restating a zero transposition through the session is nothing to apply")
    func sessionReportsNothingToApply() {
        let session = ScoreEditSession(score: Self.cMajorUndeclared())
        #expect(!session.apply(.transposeScore(
            semitones: 0, transposeKeySignatures: true, respellInKey: true,
        )))
        #expect(session.lastRefusal?.reason == .nothingToApply)
    }
}
