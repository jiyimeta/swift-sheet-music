@testable import SheetMusicCore
import Testing

/// Deleting one end of a tie must not leave the other end pointing at nothing.
///
/// The damage is audible rather than cosmetic, and it has two faces: `MidiRenderer` suppresses a note-on for a
/// note carrying `tieBack` (the sound is supposed to be running already) and a note-off for one carrying
/// `tieForward` (the sound is supposed to continue). A survivor left with a dangling `tieBack` therefore never
/// plays; one left with a dangling `tieForward` never stops.
@Suite("Dangling tie seals")
struct DanglingTieSealTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int, measure: Int = 0, voice: Int = 0) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    private static func tiedChord(
        _ pitch: Int, _ tpc: Int, _ duration: NoteDuration = .half, forward: Int? = nil, back: Int? = nil,
    ) -> VoiceElement {
        var note = Note(pitch: pitch, tpc: tpc)
        note.tieForward = forward
        note.tieBack = back
        return .chord(Chord(duration: duration, notes: [note]))
    }

    /// One 4/4 bar: `[ts, E4 h ⌣, E4 h]` — a tie inside the bar, the simplest shape the bug appears in.
    private static func tieWithinBar() -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            tiedChord(64, 18, forward: 1),
            tiedChord(64, 18, back: 1),
        ])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [Measure(voices: [voice])])])
        return Score(division: 480, parts: [part])
    }

    /// Two 4/4 bars, the tie crossing the barline: `[ts, E4 w ⌣]` `[E4 w]`.
    private static func tieAcrossBarline() -> Score {
        let first = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            tiedChord(64, 18, .whole, forward: 1),
        ])
        let second = Voice(elements: [tiedChord(64, 18, .whole, back: 1)])
        let staff = Staff(measures: [Measure(voices: [first]), Measure(voices: [second])])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
        return Score(division: 480, parts: [part])
    }

    private static func note(_ score: Score, _ location: VoiceElementID) -> Note? {
        guard case let .chord(chord)? = score[location] else { return nil }
        return chord.notes.first
    }

    @Test("deleting the HEAD leaves the survivor playable — a dangling tieBack would silence it")
    func deletingTheHeadClearsTheSurvivorsTieBack() throws {
        let session = ScoreEditSession(score: Self.tieWithinBar())
        #expect(session.apply(.delete(at: Self.slot(1))))
        let survivor = try #require(Self.note(session.score, Self.slot(2)))
        #expect(survivor.tieBack == nil)
        #expect(survivor.pitch == 64)
    }

    @Test("deleting the TAIL leaves the survivor stoppable — a dangling tieForward would hang the note")
    func deletingTheTailClearsTheSurvivorsTieForward() throws {
        let session = ScoreEditSession(score: Self.tieWithinBar())
        #expect(session.apply(.delete(at: Self.slot(2))))
        let survivor = try #require(Self.note(session.score, Self.slot(1)))
        #expect(survivor.tieForward == nil)
    }

    @Test("the seal reaches across a barline — the survivor's own bar is byte-identical")
    func sealCrossesTheBarline() throws {
        let session = ScoreEditSession(score: Self.tieAcrossBarline())
        #expect(session.apply(.delete(at: Self.slot(1))))
        let survivor = try #require(Self.note(session.score, Self.slot(0, measure: 1)))
        #expect(survivor.tieBack == nil)
    }

    @Test("deleting the tail across a barline clears the head's tieForward")
    func sealCrossesTheBarlineBackwards() throws {
        let session = ScoreEditSession(score: Self.tieAcrossBarline())
        #expect(session.apply(.delete(at: Self.slot(0, measure: 1))))
        let survivor = try #require(Self.note(session.score, Self.slot(1)))
        #expect(survivor.tieForward == nil)
    }

    @Test("a range delete over one end seals the other")
    func rangeDeleteSeals() throws {
        let session = ScoreEditSession(score: Self.tieAcrossBarline())
        let range = VoiceElementRange(start: Self.slot(1), end: Self.slot(1))
        #expect(session.apply(.deleteRange(over: range)))
        let survivor = try #require(Self.note(session.score, Self.slot(0, measure: 1)))
        #expect(survivor.tieBack == nil)
    }

    @Test("a lengthening that swallows the tail seals the head it left behind")
    func swallowingLengtheningSeals() throws {
        // `[ts, C4 q, E4 q ⌣]` `[E4 w]` — retiming the C4 to a half swallows the tied E4 in bar 1, and the E4 in
        // bar 2 is left tied back to material that is gone.
        let first = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            Self.tiedChord(60, 14, .half),
            Self.tiedChord(64, 18, .half, forward: 1),
        ])
        let second = Voice(elements: [Self.tiedChord(64, 18, .whole, back: 1)])
        let staff = Staff(measures: [Measure(voices: [first]), Measure(voices: [second])])
        let session = ScoreEditSession(score: Score(
            division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
        ))
        #expect(session.apply(.setChordDuration(at: Self.slot(1), duration: .whole)))
        let survivor = try #require(Self.note(session.score, Self.slot(0, measure: 1)))
        #expect(survivor.tieBack == nil)
    }

    @Test("a tie both of whose ends survive is left alone")
    func intactTiesAreUntouched() {
        let session = ScoreEditSession(score: Self.tieAcrossBarline())
        // An edit somewhere else in the bar — the seal pass runs, and must find nothing to do.
        #expect(session.apply(.setNotePitch(
            at: NoteID(
                staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
            ),
            pitch: 65, tpc: 13, accidental: nil,
        )))
        #expect(Self.note(session.score, Self.slot(1))?.tieForward == 1)
        #expect(Self.note(session.score, Self.slot(0, measure: 1))?.tieBack == 1)
    }

    @Test("undo restores the tie the seal cleared — the seal rides the same undo step")
    func undoRestoresTheTie() {
        let session = ScoreEditSession(score: Self.tieWithinBar())
        let before = session.score
        #expect(session.apply(.delete(at: Self.slot(1))))
        #expect(session.undo())
        #expect(session.score == before)
    }
}
