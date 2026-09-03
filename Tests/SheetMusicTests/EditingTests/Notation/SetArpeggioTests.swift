@testable import SheetMusicCore
import Testing

/// `SetArpeggio` — spec row 53, including the two-note floor and the clear that ignores it.
@Suite("SetArpeggio")
struct SetArpeggioTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    /// The parity fixture's first chord, widened to a triad so it can carry an arpeggio.
    private static func triadScore() -> (Score, VoiceElementID) {
        var score = EditingFixtures.parityFixture()
        let target = slot(0, 1)
        score[target] = .chord(Chord(duration: .quarter, notes: [
            Note(pitch: 60, tpc: 14), Note(pitch: 64, tpc: 18), Note(pitch: 67, tpc: 15),
        ]))
        return (score, target)
    }

    private static func arpeggio(_ score: Score, _ id: VoiceElementID) -> Arpeggio? {
        if case let .chord(chord)? = score[id] { chord.arpeggio } else { nil }
    }

    @Test("a write lands on a chord of two or more notes")
    func writes() throws {
        var (score, target) = Self.triadScore()
        _ = try SetArpeggio(at: target, arpeggio: Arpeggio(subtype: 4)).apply(to: &score)
        #expect(Self.arpeggio(score, target)?.subtype == 4)
        #expect(Self.arpeggio(score, target)?.isAscending == true) // 4 is UP_STRAIGHT, per Task 0
    }

    @Test("undo restores the score exactly")
    func undoIsExact() throws {
        var (score, target) = Self.triadScore()
        let before = score
        let inverse = try SetArpeggio(at: target, arpeggio: Arpeggio(subtype: 1)).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("nil clears — even on a chord that is now too small to have been given one")
    func clears() throws {
        var (score, target) = Self.triadScore()
        _ = try SetArpeggio(at: target, arpeggio: Arpeggio(subtype: 2)).apply(to: &score)
        // Shrink the chord under the floor, then clear: the clear must not be refused.
        guard case var .chord(chord) = score[target] else { Issue.record("expected a chord"); return }
        chord.notes = [Note(pitch: 60, tpc: 14)]
        score[target] = .chord(chord)
        _ = try SetArpeggio(at: target, arpeggio: nil).apply(to: &score)
        #expect(Self.arpeggio(score, target) == nil)
    }

    @Test("the siblings are untouched")
    func siblingsUntouched() throws {
        var (score, target) = Self.triadScore()
        let before = score
        _ = try SetArpeggio(at: target, arpeggio: Arpeggio(subtype: 0)).apply(to: &score)
        #expect(score.parts[1] == before.parts[1])
        #expect(score.parts[0].staves[0].measures[1...] == before.parts[0].staves[0].measures[1...])
    }

    @Test("a single-note chord, a rest and a missing element are refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let single = #expect(throws: SheetMusicError.self) {
            _ = try SetArpeggio(at: Self.slot(0, 1), arpeggio: Arpeggio(subtype: 1)).apply(to: &score)
        }
        #expect(Self.reason(of: single) == .chordTooSmall(at: Self.slot(0, 1), noteCount: 1))
        let onRest = #expect(throws: SheetMusicError.self) {
            _ = try SetArpeggio(at: Self.slot(0, 3), arpeggio: Arpeggio(subtype: 1)).apply(to: &score)
        }
        #expect(Self.reason(of: onRest) == .wrongElementKind(at: Self.slot(0, 3), expected: .chord))
        let missing = #expect(throws: SheetMusicError.self) {
            _ = try SetArpeggio(at: Self.slot(0, 9), arpeggio: nil).apply(to: &score)
        }
        #expect(Self.reason(of: missing) == .targetNotFound(Self.slot(0, 9)))
        #expect(score == before)
    }
}
