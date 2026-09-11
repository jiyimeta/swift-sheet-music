@testable import SheetMusicCore
import Testing

@Suite("Per-note flag commands")
struct SetNoteFlagCommandTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let note = NoteID(
        staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
    )
    private static let absentNote = NoteID(
        staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 7,
    )

    @Test("small is written and the inverse restores the previous flag")
    func smallRoundTrips() throws {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        let inverse = try SetNoteSmall(at: Self.note, isSmall: true).apply(to: &score)
        #expect(score[Self.note]?.isSmall == true)
        try inverse.apply(to: &score)
        #expect(score[Self.note]?.isSmall == false)
    }

    @Test("play is written and the inverse restores the previous flag")
    func playRoundTrips() throws {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        let inverse = try SetNotePlay(at: Self.note, play: false).apply(to: &score)
        #expect(score[Self.note]?.play == false)
        try inverse.apply(to: &score)
        #expect(score[Self.note]?.play == true)
    }

    @Test("a note index past the end of the chord is refused")
    func refusesAbsentNote() {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        #expect(throws: SheetMusicError.self) {
            try SetNoteSmall(at: Self.absentNote, isSmall: true).apply(to: &score)
        }
        #expect(throws: SheetMusicError.self) {
            try SetNotePlay(at: Self.absentNote, play: false).apply(to: &score)
        }
    }

    @Test("writing one note leaves its neighbour in the chord alone")
    func doesNotFanOutAcrossTheChord() throws {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        let anchor = VoiceElementID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        guard case var .chord(chord)? = score[anchor] else { Issue.record("missing chord"); return }
        chord.notes = ChordNotes(Array(chord.notes) + [Note(pitch: 64, tpc: 18)])
        score[anchor] = .chord(chord)

        try SetNoteSmall(at: Self.note, isSmall: true).apply(to: &score)
        let neighbour = NoteID(
            staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 1,
        )
        #expect(score[Self.note]?.isSmall == true)
        #expect(score[neighbour]?.isSmall == false)
    }
}
