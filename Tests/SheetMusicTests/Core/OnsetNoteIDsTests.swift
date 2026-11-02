@testable import SheetMusicCore
import Testing

@Suite("Score.onsetNoteIDs")
struct OnsetNoteIDsTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func chord(_ duration: NoteDuration, _ pitches: [Int]) -> VoiceElement {
        .chord(Chord(duration: duration, notes: ChordNotes(pitches.map { Note(pitch: $0, tpc: 14) })))
    }

    private static func rest(_ duration: NoteDuration) -> VoiceElement {
        .chord(Chord(duration: duration, notes: []))
    }

    /// A drum bar written the usual way: hands in voice 1, feet in voice 2.
    ///
    /// - voice 1: time signature, crash+snare (q), rest (q), hi-hat (q) — or a rest, `beatThree` — hi-hat (q)
    /// - voice 2: kick (h), kick (q), kick (q)
    private static func score(beatThree: VoiceElement = chord(.quarter, [42])) -> Score {
        let hands = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            chord(.quarter, [49, 38]),
            rest(.quarter),
            beatThree,
            chord(.quarter, [42]),
        ])
        let feet = Voice(elements: [
            chord(.half, [36]),
            chord(.quarter, [36]),
            chord(.quarter, [36]),
        ])
        let staff = Staff(measures: [Measure(voices: [hands, feet])])
        return Score(division: 480, parts: [Part(id: "p0", instrument: Instrument(id: "drums"), staves: [staff])])
    }

    private static func note(voice: Int, element: Int, index: Int = 0) -> NoteID {
        NoteID(staff: staff, measureIndex: 0, voiceIndex: voice, elementIndex: element, noteIndexInChord: index)
    }

    @Test("a note sounds every note of every voice that starts with it")
    func noteCollectsAllVoices() {
        let ids = Self.score().onsetNoteIDs(of: .note(Self.note(voice: 0, element: 1, index: 1)))
        #expect(ids == [
            Self.note(voice: 0, element: 1, index: 0),
            Self.note(voice: 0, element: 1, index: 1),
            Self.note(voice: 1, element: 0),
        ])
    }

    @Test("a note in the lower voice collects the upper voice too")
    func lowerVoiceCollectsUpper() {
        let ids = Self.score().onsetNoteIDs(of: .note(Self.note(voice: 1, element: 1)))
        #expect(ids == [Self.note(voice: 0, element: 3), Self.note(voice: 1, element: 1)])
    }

    @Test("a rest on an onset another voice fills sounds that voice")
    func restSoundsOtherVoice() {
        let rest = RestID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
        // The rest begins at beat 2, where voice 2's half-note kick is still ringing — it began on beat 1, so nothing
        // starts here.
        #expect(Self.score().onsetNoteIDs(of: .rest(rest)).isEmpty)
    }

    @Test("a rest whose onset another voice starts a note on sounds that note")
    func restOnSharedOnset() {
        // Beat 3's hi-hat is a rest: voice 2's kick still starts there.
        let score = Self.score(beatThree: Self.rest(.quarter))
        let rest = RestID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 3)
        #expect(score.onsetNoteIDs(of: .rest(rest)) == [Self.note(voice: 1, element: 1)])
    }

    @Test("an item that names no slot sounds nothing")
    func nonSlotItem() {
        let tuplet = TupletID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, startElementIndex: 1)
        #expect(Self.score().onsetNoteIDs(of: .tuplet(tuplet)).isEmpty)
    }

    @Test("an address that does not resolve sounds nothing")
    func unresolvedAddress() {
        let stale = NoteID(staff: Self.staff, measureIndex: 3, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0)
        #expect(Self.score().onsetNoteIDs(of: .note(stale)).isEmpty)
    }
}
