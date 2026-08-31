@testable import SheetMusicCore
import Testing

@Suite("Drum note-entry intents")
struct DrumIntentTests {
    private static let staff = EditingFixtures.staff0

    private static func slot(measure: Int = 0, voice: Int = 0, element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    @Test("createVoice grows the measure")
    func createVoiceApplies() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())

        #expect(session.apply(.createVoice(staff: Self.staff, measureIndex: 0, voiceIndex: 1)))

        #expect(session.score.parts[0].staves[0].measures[0].voices.count == 2)
    }

    /// A voice that is already there is nothing to do, not a refusal: the drum pad composes
    /// `[createVoice, writeNote]` on every key press and cannot know which bars already have the feet voice.
    /// Refusing here would take the note write down with it, since a composite is all-or-nothing.
    @Test("createVoice on a voice that exists plans to nothing rather than refusing")
    func createVoicePlansToNothing() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())

        #expect(!session.apply(.createVoice(staff: Self.staff, measureIndex: 0, voiceIndex: 0)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(session.score.parts[0].staves[0].measures[0].voices.count == 1)
    }

    @Test("splitRest makes a slot boundary at the caret's tick")
    func splitRestApplies() {
        var score = EditingFixtures.fourQuarterRests()
        score.parts[0].staves[0].measures[0].voices[0].elements = [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .half),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ]
        let session = ScoreEditSession(score: score)

        #expect(session.apply(.splitRest(at: Self.slot(element: 1), tickOffset: 480)))

        #expect(session.score.parts[0].staves[0].measures[0].voices[0].elements.count == 5)
    }

    @Test("setNoteHead writes the head")
    func setNoteHeadApplies() {
        let session = ScoreEditSession(score: EditingFixtures.chordAtIndex1())

        #expect(session.apply(.setNoteHead(at: EditingFixtures.noteID(element: 1), headType: "cross")))

        guard case let .chord(chord) = session.score[Self.slot(element: 1)] else {
            Issue.record("expected a chord"); return
        }
        #expect(chord.notes[0].headType == "cross")
    }

    /// The shape the drum pad actually issues: write the note, then stamp its head, as ONE undo step. The head
    /// intent addresses a note that does not exist when the composite is PLANNED — planning builds commands from
    /// scalars without touching the score, and the composite applies them in order, so by the time `SetNoteHead`
    /// runs the note is there.
    @Test("a note and its head are one undo step")
    func writeWithHeadIsOneUndoStep() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let rest = EditingFixtures.restID(element: 1)
        let note = EditingFixtures.noteID(element: 1)

        #expect(session.apply(.composite([
            .inputNote(at: rest, pitch: 42, tpc: 14, duration: .quarter),
            .setNoteHead(at: note, headType: "cross"),
        ])))

        guard case let .chord(chord) = session.score[Self.slot(element: 1)] else {
            Issue.record("expected a chord"); return
        }
        #expect(chord.notes[0].pitch == 42)
        #expect(chord.notes[0].headType == "cross")

        #expect(session.undo())
        #expect(session.score == EditingFixtures.fourQuarterRests())
    }
}
