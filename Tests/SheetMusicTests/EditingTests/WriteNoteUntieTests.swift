@testable import SheetMusicCore
import Testing

/// Typing a note over a tied note writes a NEW note: the ties the old one carried go with it.
///
/// `.writeNote` used to re-pitch the slot with a bare `SetNotePitch`, which leaves `tieForward` / `tieBack` exactly
/// where they were. `TiePlanner` pairs ties by rank, not by pitch, so `DanglingTies` saw nothing wrong either: the
/// overwritten note stayed tied to a neighbour at a different pitch. Two things then went wrong for the user —
/// `MidiRenderer` suppressed the neighbour's note-on (its `tieBack` says the sound is already running), so it never
/// played; and a later ↑ / ↓ on the overwritten note walked the surviving "chain" and dragged the neighbour along,
/// so the tie seemed to reappear the moment the two pitches met again. MuseScore replaces the chord when a pitch is
/// typed over it, and the replaced note's ties are removed with it.
@Suite("writeNote unties the note it overwrites")
struct WriteNoteUntieTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    private static func noteID(_ element: Int) -> NoteID {
        NoteID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element, noteIndexInChord: 0)
    }

    private static func chord(
        _ pitch: Int, _ tpc: Int, _ duration: NoteDuration, forward: Int? = nil, back: Int? = nil,
    ) -> VoiceElement {
        var note = Note(pitch: pitch, tpc: tpc)
        note.tieForward = forward
        note.tieBack = back
        return .chord(Chord(duration: duration, notes: [note]))
    }

    private static func score(_ elements: [VoiceElement]) -> Score {
        let voice = Voice(elements: [.timeSignature(TimeSignature(numerator: 4, denominator: 4))] + elements)
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [Measure(voices: [voice])])])
        return Score(division: 480, parts: [part])
    }

    /// `[ts, E4 h ⌣, E4 h]`
    private static func tiedPair() -> Score {
        score([chord(64, 18, .half, forward: 1), chord(64, 18, .half, back: 1)])
    }

    /// `[ts, E4 q ⌣, E4 q ⌣, E4 q, G4 q]`
    private static func tiedTriple() -> Score {
        score([
            chord(64, 18, .quarter, forward: 1),
            chord(64, 18, .quarter, forward: 1, back: 1),
            chord(64, 18, .quarter, back: 1),
            chord(67, 15, .quarter),
        ])
    }

    private static func note(_ score: Score, _ element: Int) -> Note? {
        guard case let .chord(chord)? = score[slot(element)] else { return nil }
        return chord.notes.first
    }

    @Test("a new pitch over the HEAD clears both ends, and the tail keeps its own pitch")
    func overwritingTheHead() throws {
        let session = ScoreEditSession(score: Self.tiedPair())
        #expect(session.apply(.writeNote(at: Self.slot(1), pitch: 67, tpc: 15, duration: nil)))
        let head = try #require(Self.note(session.score, 1))
        let tail = try #require(Self.note(session.score, 2))
        #expect(head.pitch == 67)
        #expect(head.tieForward == nil)
        #expect(tail.tieBack == nil)
        #expect(tail.pitch == 64)
    }

    @Test("a new pitch over the TAIL clears both ends — the head's sound is released again")
    func overwritingTheTail() throws {
        let session = ScoreEditSession(score: Self.tiedPair())
        #expect(session.apply(.writeNote(at: Self.slot(2), pitch: 67, tpc: 15, duration: nil)))
        let head = try #require(Self.note(session.score, 1))
        let tail = try #require(Self.note(session.score, 2))
        #expect(head.tieForward == nil)
        #expect(tail.tieBack == nil)
        #expect(tail.pitch == 67)
        #expect(head.pitch == 64)
    }

    @Test("a later pitch step on the overwritten note moves it alone — no tie comes back")
    func pitchStepAfterOverwriteMovesOnlyThatNote() throws {
        let session = ScoreEditSession(score: Self.tiedPair())
        #expect(session.apply(.writeNote(at: Self.slot(1), pitch: 65, tpc: 13, duration: nil)))
        #expect(session.apply(.setNotePitch(at: Self.noteID(1), pitch: 64, tpc: 18, accidental: nil)))
        let head = try #require(Self.note(session.score, 1))
        let tail = try #require(Self.note(session.score, 2))
        #expect(head.pitch == 64)
        #expect(tail.pitch == 64)
        #expect(head.tieForward == nil)
        #expect(tail.tieBack == nil)
    }

    @Test("over the middle of a chain, both neighbours let go")
    func overwritingTheMiddleOfAChain() throws {
        let session = ScoreEditSession(score: Self.tiedTriple())
        #expect(session.apply(.writeNote(at: Self.slot(2), pitch: 67, tpc: 15, duration: nil)))
        let first = try #require(Self.note(session.score, 1))
        let middle = try #require(Self.note(session.score, 2))
        let last = try #require(Self.note(session.score, 3))
        #expect(first.tieForward == nil)
        #expect(middle.tieBack == nil)
        #expect(middle.tieForward == nil)
        #expect(last.tieBack == nil)
        #expect(last.pitch == 64)
    }

    @Test("the same pitch typed over a tied note still writes a fresh, untied note")
    func samePitchOverwriteUnties() throws {
        let session = ScoreEditSession(score: Self.tiedPair())
        #expect(session.apply(.writeNote(at: Self.slot(1), pitch: 64, tpc: 18, duration: nil)))
        let head = try #require(Self.note(session.score, 1))
        let tail = try #require(Self.note(session.score, 2))
        #expect(head.tieForward == nil)
        #expect(tail.tieBack == nil)
    }

    @Test("an overwrite that also re-times unties too")
    func overwriteWithARetimeUnties() {
        let session = ScoreEditSession(score: Self.tiedPair())
        #expect(session.apply(.writeNote(at: Self.slot(1), pitch: 67, tpc: 15, duration: .quarter)))
        guard case let .chord(head)? = session.score[Self.slot(1)] else {
            Issue.record("slot 1 is no longer a chord")
            return
        }
        #expect(head.duration == .quarter)
        #expect(head.notes.first?.tieForward == nil)
        let survivors = session.score[Self.staff0]?.measures[0].voices[0].elements.compactMap { element -> Note? in
            guard case let .chord(chord) = element else { return nil }
            return chord.notes.first(where: { $0.pitch == 64 })
        } ?? []
        #expect(survivors.count == 1)
        #expect(survivors.allSatisfy { $0.tieBack == nil })
    }

    @Test("one undo puts the tie and the old pitch back")
    func undoRestoresTheTie() throws {
        let session = ScoreEditSession(score: Self.tiedPair())
        #expect(session.apply(.writeNote(at: Self.slot(1), pitch: 67, tpc: 15, duration: nil)))
        #expect(session.undo())
        let head = try #require(Self.note(session.score, 1))
        let tail = try #require(Self.note(session.score, 2))
        #expect(head.pitch == 64)
        #expect(head.tieForward == 1)
        #expect(tail.tieBack == 1)
    }

    @Test("a write followed by a tie in one composite still ties — the tie-append shape")
    func writeThenTieInOneComposite() throws {
        let session = ScoreEditSession(score: Self.score([Self.chord(64, 18, .half), Self.chord(67, 15, .half)]))
        #expect(session.apply(.composite([
            .writeNote(at: Self.slot(2), pitch: 64, tpc: 18, duration: nil),
            .setTie(from: Self.noteID(1), to: Self.noteID(2), sourceTieForward: 1, targetTieBack: 1),
        ])))
        let head = try #require(Self.note(session.score, 1))
        let tail = try #require(Self.note(session.score, 2))
        #expect(tail.pitch == 64)
        #expect(head.tieForward == 1)
        #expect(tail.tieBack == 1)
    }
}
