@testable import SheetMusicCore
import Testing

@Suite("DeleteVoiceElement")
struct DeleteVoiceElementTests {
    private static let chordID = VoiceElementID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 1
    )

    @Test("apply replaces a chord with a rest of the same duration")
    func applyChord() throws {
        var score = EditingFixtures.chordAtIndex1()
        let cmd = DeleteVoiceElement(at: Self.chordID)
        _ = try cmd.apply(to: &score)
        let after = try #require(score[Self.chordID])
        guard case let .chord(r) = after, r.notes.isEmpty else {
            Issue.record("Expected rest after delete, got \(after)")
            return
        }
        #expect(r.duration == .quarter)
    }

    @Test("inverse restores the original chord with all notes / TPC")
    func inverseRestoresChord() throws {
        var score = EditingFixtures.chordAtIndex1()
        let original = score
        let cmd = DeleteVoiceElement(at: Self.chordID)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("apply on a rest is idempotent")
    func applyRest() throws {
        var score = EditingFixtures.fourQuarterRests()
        let restID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 2
        )
        let before = score
        let cmd = DeleteVoiceElement(at: restID)
        let inverse = try cmd.apply(to: &score)
        #expect(score == before)
        // Inverse on no-op still round-trips cleanly.
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("apply throws on a non-chord / non-rest element")
    func applyOnTimeSignature() {
        var score = EditingFixtures.fourQuarterRests()
        let timeSigID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 0
        )
        let cmd = DeleteVoiceElement(at: timeSigID)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }

    @Test("apply throws when the path is out of range")
    func applyMissing() {
        var score = EditingFixtures.fourQuarterRests()
        let bogus = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 99
        )
        let cmd = DeleteVoiceElement(at: bogus)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
