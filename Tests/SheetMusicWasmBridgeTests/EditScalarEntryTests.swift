import SheetMusicCore
@testable import SheetMusicWasmBridge
import Testing

@Suite("scalar edit entry points")
struct EditScalarEntryTests {
    static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    static let slot1 = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
    static let note0 = NoteID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0)
    static let note1 = NoteID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 1)
    static let note2 = NoteID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2, noteIndexInChord: 0)

    struct ScalarCase {
        var score: () throws -> Score
        var intent: EditIntent
        var applyViaBridge: (Int) -> EditOutcome
    }

    @Test("entry point and direct EditIntent application produce the same fingerprint")
    func scalarEntryPointsMatchDirectApplication() throws {
        let cases = Self.scalarCases()
        #expect(cases.count == 13)
        for scalarCase in cases {
            let score = try scalarCase.score()
            let before = score.stableFingerprint
            let direct = ScoreEditSession(score: score)
            #expect(direct.apply(scalarCase.intent))
            let directFingerprint = direct.score.stableFingerprint
            #expect(directFingerprint != before)

            let handle = Self.handle(for: score)
            defer { releaseScore(handle: handle) }
            #expect(beginEditSession(handle: handle))
            #expect(scalarCase.applyViaBridge(handle).accepted)
            #expect(scoreFingerprint(handle: handle) == String(directFingerprint))
            #expect(scoreFingerprint(handle: handle) != String(before))
        }
    }

    @Test("refusals preserve structured edit and bridge channels")
    func scalarRefusalsPreserveChannels() {
        let handle = Self.handle(for: Self.chordAtIndex1())
        defer { releaseScore(handle: handle) }
        #expect(beginEditSession(handle: handle))
        let before = scoreFingerprint(handle: handle)

        let outOfRange = editDelete(
            handle: handle, partIndex: 0, staffIndexInPart: 0, measureIndex: 99,
            voiceIndex: 0, elementIndex: 0,
        )
        #expect(outOfRange.accepted == false)
        #expect(outOfRange.code == "edit.targetNotFound")
        #expect(scoreFingerprint(handle: handle) == before)
        #expect(editSessionState(handle: handle).canUndo == false)

        Self.expectInvalid(editSetRestDuration(
            handle: handle, partIndex: 0, staffIndexInPart: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1, durationKind: 99,
            durationNumerator: 0, durationDenominator: 0,
        ), operation: "editSetRestDuration")
        Self.expectInvalid(editSetChordDuration(
            handle: handle, partIndex: 0, staffIndexInPart: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1, durationKind: 10,
            durationNumerator: 0, durationDenominator: 0,
        ), operation: "editSetChordDuration")
        Self.expectInvalid(editWriteNote(
            handle: handle, partIndex: 0, staffIndexInPart: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1, pitch: 60, tpc: 14,
            durationKind: 10, durationNumerator: 0, durationDenominator: 0,
        ), operation: "editWriteNote")
        Self.expectInvalid(editSetAccidental(
            handle: handle, partIndex: 0, staffIndexInPart: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
            accidental: "notAnAccidental",
        ), operation: "editSetAccidental")
        Self.expectInvalid(editCreateTuplet(
            handle: handle, partIndex: 0, staffIndexInPart: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1, actualNotes: 3, normalNotes: 0,
        ), operation: "editCreateTuplet")

        #expect(scoreFingerprint(handle: handle) == before)
        #expect(editSessionState(handle: handle).canUndo == false)
    }

    static func scalarCases() -> [ScalarCase] {
        [
            inputNoteCase(), setRestDurationCase(), setChordDurationCase(), deleteCase(),
            setNotePitchCase(), setAccidentalCase(), addNoteToChordCase(), removeNoteFromChordCase(),
            setTieCase(), createTupletCase(), removeTupletCase(), writeNoteCase(), writeRestCase(),
        ]
    }

    static func handle(for score: Score) -> Int {
        Int(scoreTable.insert(score))
    }

    static func expectInvalid(_ outcome: EditOutcome, operation: String) {
        #expect(outcome.accepted == false)
        #expect(outcome.code == "bridge.invalidArgument")
        #expect(outcome.operation == operation)
    }

    static func fourQuarterRests() -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ])
        return Score(division: 480, parts: [Part(
            id: "1",
            instrument: Instrument(id: "x"),
            staves: [Staff(measures: [Measure(voices: [voice])])],
        )])
    }

    static func chordAtIndex1() -> Score {
        var score = fourQuarterRests()
        score[slot1] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        return score
    }

    static func twoNoteChordAtIndex1() -> Score {
        var score = fourQuarterRests()
        score[slot1] = .chord(Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14), Note(pitch: 64, tpc: 18)],
        ))
        return score
    }

    static func twoConsecutiveC4Chords() -> Score {
        var score = fourQuarterRests()
        let c4 = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        score[slot1] = .chord(c4)
        score[VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)] = .chord(c4)
        return score
    }

    static func tripletScore() throws -> Score {
        var score = fourQuarterRests()
        _ = try CreateTuplet(at: slot1, actualNotes: 3, normalNotes: 2).apply(to: &score)
        return score
    }
}
