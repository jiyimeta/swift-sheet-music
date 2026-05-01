@testable import SheetMusicCore
import Testing

@Suite("SetAccidental")
struct SetAccidentalTests {
    private static let chordVE = VoiceElementID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 1)
    private static let noteID = NoteID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0)

    @Test("sharp on C natural becomes C♯ (+1 semitone)")
    func sharpOnNaturalC() throws {
        var score = EditingFixtures.chordAtIndex1() // C4 (60, tpc 14)
        let cmd = SetAccidental(at: Self.noteID, accidental: .sharp)
        _ = try cmd.apply(to: &score)
        guard case .chord(let c) = score[Self.chordVE] else {
            Issue.record("not chord"); return
        }
        let n = c.notes[0]
        #expect(n.pitch == 61)
        #expect(n.tpc == 21)         // C♯
        #expect(n.accidental == .sharp)
    }

    @Test("flat on C natural becomes C♭ (−1 semitone)")
    func flatOnNaturalC() throws {
        var score = EditingFixtures.chordAtIndex1()
        let cmd = SetAccidental(at: Self.noteID, accidental: .flat)
        _ = try cmd.apply(to: &score)
        guard case .chord(let c) = score[Self.chordVE] else {
            Issue.record("not chord"); return
        }
        let n = c.notes[0]
        #expect(n.pitch == 59)
        #expect(n.tpc == 7)          // C♭
        #expect(n.accidental == .flat)
    }

    @Test("preserves the diatonic letter when retoning a flat")
    func sharpOnDFlat() throws {
        var score = EditingFixtures.fourQuarterRests()
        // D♭4: pitch 61, tpc 9, accidental .flat.
        score[Self.chordVE] = .chord(Chord(
            duration: .quarter,
            notes: [Note(pitch: 61, tpc: 9, accidental: .flat)]))
        let cmd = SetAccidental(at: Self.noteID, accidental: .sharp)
        _ = try cmd.apply(to: &score)
        guard case .chord(let c) = score[Self.chordVE] else {
            Issue.record("not chord"); return
        }
        let n = c.notes[0]
        #expect(n.pitch == 63)       // D♯
        #expect(n.tpc == 23)         // D♯
        #expect(n.accidental == .sharp)
    }

    @Test("nil clears the glyph without changing pitch / tpc")
    func nilClearsDisplay() throws {
        var score = EditingFixtures.fourQuarterRests()
        // C♯4 with accidental display.
        score[Self.chordVE] = .chord(Chord(
            duration: .quarter,
            notes: [Note(pitch: 61, tpc: 21, accidental: .sharp)]))
        let cmd = SetAccidental(at: Self.noteID, accidental: nil)
        _ = try cmd.apply(to: &score)
        guard case .chord(let c) = score[Self.chordVE] else {
            Issue.record("not chord"); return
        }
        let n = c.notes[0]
        #expect(n.pitch == 61)
        #expect(n.tpc == 21)
        #expect(n.accidental == nil)
    }

    @Test("inverse round-trips pitch, tpc, and accidental")
    func inverseRestores() throws {
        var score = EditingFixtures.fourQuarterRests()
        score[Self.chordVE] = .chord(Chord(
            duration: .quarter,
            notes: [Note(pitch: 61, tpc: 9, accidental: .flat)]))
        let snapshot = score
        let cmd = SetAccidental(at: Self.noteID, accidental: .sharp)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("apply throws when target is not a chord")
    func refusesOnRest() {
        var score = EditingFixtures.fourQuarterRests()
        let restNoteID = NoteID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 2, noteIndexInChord: 0)
        let cmd = SetAccidental(at: restNoteID, accidental: .sharp)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
