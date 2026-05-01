@testable import SheetMusicCore
import Testing

@Suite("InputNote")
struct InputNoteTests {
    private static let restAt1 = RestID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 1
    )

    @Test("apply replaces the rest with a single-note chord at the same duration")
    func applyReplacesRest() throws {
        var score = EditingFixtures.fourQuarterRests()
        let cmd = InputNote(at: Self.restAt1, pitch: 60, tpc: 14) // C4
        _ = try cmd.apply(to: &score)
        let veID = VoiceElementID(Self.restAt1)
        guard case let .chord(chord) = score[veID] else {
            Issue.record("expected chord")
            return
        }
        #expect(chord.duration == .quarter)
        #expect(chord.notes.count == 1)
        #expect(chord.notes[0].pitch == 60)
        #expect(chord.notes[0].tpc == 14)
    }

    @Test("inverse restores the original rest")
    func inverseRestoresRest() throws {
        var score = EditingFixtures.fourQuarterRests()
        let original = score
        let cmd = InputNote(at: Self.restAt1, pitch: 60, tpc: 14)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("apply throws when target is not a rest")
    func applyOnChord() throws {
        var score = EditingFixtures.chordAtIndex1()
        let cmd = InputNote(at: Self.restAt1, pitch: 62, tpc: 16)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
