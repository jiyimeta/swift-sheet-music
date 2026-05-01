@testable import SheetMusicCore
import Testing

@Suite("RemoveNoteFromChord")
struct RemoveNoteFromChordTests {
    private static let chordVE = VoiceElementID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 1)

    @Test("apply drops one note from a multi-note chord")
    func dropsNote() throws {
        var score = EditingFixtures.chordAtIndex1()
        // Add a second note so removal leaves a chord, not a rest.
        if case .chord(var chord) = score[Self.chordVE] {
            chord.notes.append(Note(pitch: 64, tpc: 18)) // E4
            score[Self.chordVE] = .chord(chord)
        }
        let removeID = NoteID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1, noteIndexInChord: 1)
        let cmd = RemoveNoteFromChord(at: removeID)
        _ = try cmd.apply(to: &score)
        guard case .chord(let chord) = score[Self.chordVE] else {
            Issue.record("not a chord"); return
        }
        #expect(chord.notes.count == 1)
        #expect(chord.notes[0].pitch == 60)
    }

    @Test("removing the last note collapses the chord to a rest")
    func collapsesToRest() throws {
        var score = EditingFixtures.chordAtIndex1()
        let removeID = NoteID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0)
        let cmd = RemoveNoteFromChord(at: removeID)
        _ = try cmd.apply(to: &score)
        guard case .rest(let rest) = score[Self.chordVE] else {
            Issue.record("not a rest"); return
        }
        #expect(rest.duration == .quarter)
    }

    @Test("inverse restores chord (with metadata) after collapse")
    func inverseRestoresAfterCollapse() throws {
        var score = EditingFixtures.fourQuarterRests()
        score[Self.chordVE] = .chord(Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
            lyrics: [Lyric(text: "do")]))
        let snapshot = score
        let removeID = NoteID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0)
        let cmd = RemoveNoteFromChord(at: removeID)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("inverse restores chord after partial removal")
    func inverseRestoresAfterPartialRemoval() throws {
        var score = EditingFixtures.chordAtIndex1()
        if case .chord(var chord) = score[Self.chordVE] {
            chord.notes.append(Note(pitch: 64, tpc: 18))
            score[Self.chordVE] = .chord(chord)
        }
        let snapshot = score
        let removeID = NoteID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1, noteIndexInChord: 1)
        let cmd = RemoveNoteFromChord(at: removeID)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("apply throws when the target is not a chord")
    func refusesOnRest() {
        var score = EditingFixtures.fourQuarterRests()
        let restNoteID = NoteID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 2, noteIndexInChord: 0)
        let cmd = RemoveNoteFromChord(at: restNoteID)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }

    @Test("apply throws when noteIndexInChord is out of range")
    func refusesOnOutOfRange() {
        var score = EditingFixtures.chordAtIndex1()
        let badID = NoteID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1, noteIndexInChord: 7)
        let cmd = RemoveNoteFromChord(at: badID)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
