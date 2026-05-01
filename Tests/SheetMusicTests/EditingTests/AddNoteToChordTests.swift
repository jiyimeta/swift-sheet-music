@testable import SheetMusicCore
import Testing

@Suite("AddNoteToChord")
struct AddNoteToChordTests {
    private static let chordID = VoiceElementID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 1)

    @Test("apply appends a new note to the chord")
    func appendsNote() throws {
        var score = EditingFixtures.chordAtIndex1()
        let cmd = AddNoteToChord(
            at: Self.chordID, pitch: 64, tpc: 18) // E4
        _ = try cmd.apply(to: &score)
        guard case .chord(let chord) = score[Self.chordID] else {
            Issue.record("not chord"); return
        }
        #expect(chord.notes.count == 2)
        #expect(chord.notes[0].pitch == 60)
        #expect(chord.notes[1].pitch == 64)
        #expect(chord.notes[1].tpc == 18)
    }

    @Test("apply preserves chord-level metadata (duration, lyrics)")
    func preservesChordMetadata() throws {
        // Build a chord with a lyric attached.
        var score = EditingFixtures.fourQuarterRests()
        let id = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1)
        score[id] = .chord(Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
            lyrics: [Lyric(text: "do")]))
        let cmd = AddNoteToChord(at: id, pitch: 67, tpc: 15)
        _ = try cmd.apply(to: &score)
        guard case .chord(let chord) = score[id] else {
            Issue.record("not chord"); return
        }
        #expect(chord.duration == .quarter)
        #expect(chord.lyrics.first?.text == "do")
        #expect(chord.notes.count == 2)
    }

    @Test("inverse restores the original chord")
    func inverseRestores() throws {
        var score = EditingFixtures.chordAtIndex1()
        let snapshot = score
        let cmd = AddNoteToChord(
            at: Self.chordID, pitch: 64, tpc: 18)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("apply refuses a duplicate pitch")
    func refusesDuplicate() {
        var score = EditingFixtures.chordAtIndex1()
        let cmd = AddNoteToChord(
            at: Self.chordID, pitch: 60, tpc: 14)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }

    @Test("apply throws when the target is not a chord")
    func refusesOnRest() {
        var score = EditingFixtures.fourQuarterRests()
        let restID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 2)
        let cmd = AddNoteToChord(
            at: restID, pitch: 60, tpc: 14)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
