@testable import SheetMusicCore
import Testing

@Suite("SetNotePitch")
struct SetNotePitchTests {
    private static let c4 = NoteID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0,
        elementIndex: 1, noteIndexInChord: 0,
    )

    @Test("apply changes pitch and tpc")
    func applyChanges() throws {
        var score = EditingFixtures.chordAtIndex1()
        let cmd = SetNotePitch(at: Self.c4, pitch: 62, tpc: 16) // D4
        _ = try cmd.apply(to: &score)
        let note = try #require(score[Self.c4])
        #expect(note.pitch == 62)
        #expect(note.tpc == 16)
    }

    @Test("inverse restores prior pitch and tpc")
    func inverseRestores() throws {
        var score = EditingFixtures.chordAtIndex1()
        let original = score
        let cmd = SetNotePitch(at: Self.c4, pitch: 62, tpc: 16)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("apply throws when the path doesn't resolve to a note")
    func applyMissing() {
        var score = EditingFixtures.fourQuarterRests() // index 1 is a rest
        let cmd = SetNotePitch(at: Self.c4, pitch: 62, tpc: 16)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
