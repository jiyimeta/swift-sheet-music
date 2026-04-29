@testable import SheetMusicCore
import Testing

@Suite("ReplaceVoiceElement")
struct ReplaceVoiceElementTests {
    private static let restAt1 = VoiceElementID(
        staffIndex: 0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
    private static let outOfRange = VoiceElementID(
        staffIndex: 0, measureIndex: 0, voiceIndex: 0, elementIndex: 99)

    @Test("apply replaces the element")
    func applyReplaces() throws {
        var score = EditingFixtures.fourQuarterRests()
        let chord = Chord(duration: .quarter,
                          notes: [Note(pitch: 60, tpc: 14)])
        let cmd = ReplaceVoiceElement(at: Self.restAt1, with: .chord(chord))
        _ = try cmd.apply(to: &score)
        guard case let .chord(c) = score[Self.restAt1] else {
            Issue.record("expected chord at index 1")
            return
        }
        #expect(c.notes.first?.pitch == 60)
    }

    @Test("inverse restores the original element")
    func inverseRestores() throws {
        var score = EditingFixtures.fourQuarterRests()
        let original = score
        let chord = Chord(duration: .quarter,
                          notes: [Note(pitch: 60, tpc: 14)])
        let cmd = ReplaceVoiceElement(at: Self.restAt1, with: .chord(chord))
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("apply throws invalidEdit for an out-of-range path")
    func applyOutOfRange() {
        var score = EditingFixtures.fourQuarterRests()
        let chord = Chord(duration: .quarter,
                          notes: [Note(pitch: 60, tpc: 14)])
        let cmd = ReplaceVoiceElement(
            at: Self.outOfRange, with: .chord(chord))
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
