@testable import SheetMusicCore
import Testing

@Suite("AddIntervalToSelection")
struct AddIntervalToSelectionTests {
    private static let slot = VoiceElementID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0, elementIndex: 1,
    )
    private static let range = VoiceElementRange(start: slot, end: slot)

    private static func pitches(_ score: Score) -> [(Int, Int)] {
        guard case let .chord(chord)? = score[slot] else { return [] }
        return chord.notes.map { ($0.pitch, $0.tpc) }
    }

    @Test("a third above C4 adds E4, spelled in key")
    func thirdAbove() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try AddIntervalToSelection(over: Self.range, steps: 3).apply(to: &score)
        #expect(Self.pitches(score).map(\.0) == [60, 64])
        #expect(Self.pitches(score).map(\.1) == [14, 18])
    }

    @Test("below uses the lowest note; above uses the highest")
    func referenceNote() throws {
        var below = EditingFixtures.twoNoteChordAtIndex1() // C4 + E4
        _ = try AddIntervalToSelection(over: Self.range, steps: -3).apply(to: &below)
        #expect(Self.pitches(below).map(\.0) == [60, 64, 57]) // A3 under C4
        #expect(Self.pitches(below).last?.1 == 17)
        var above = EditingFixtures.twoNoteChordAtIndex1()
        _ = try AddIntervalToSelection(over: Self.range, steps: 3).apply(to: &above)
        #expect(Self.pitches(above).map(\.0) == [60, 64, 67]) // G4 over E4
    }

    @Test("an octave keeps the spelling; a unison is a duplicate and is skipped, not refused")
    func octaveAndUnison() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try AddIntervalToSelection(over: Self.range, steps: 8).apply(to: &score)
        #expect(Self.pitches(score).map(\.0) == [60, 72])
        #expect(Self.pitches(score).map(\.1) == [14, 14])
        let before = score
        _ = try AddIntervalToSelection(over: Self.range, steps: 1).apply(to: &score)
        #expect(score == before)
    }

    @Test("undo restores the score exactly")
    func undoIsExact() throws {
        var score = EditingFixtures.twoNoteChordAtIndex1()
        let before = score
        let inverse = try AddIntervalToSelection(over: Self.range, steps: -6).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("rests in the range are left alone")
    func restsAreLeftAlone() throws {
        var score = EditingFixtures.chordAtIndex1()
        let wide = VoiceElementRange(start: Self.slot, end: Self.slot.withElementIndex(4))
        _ = try AddIntervalToSelection(over: wide, steps: 5).apply(to: &score)
        #expect(Self.pitches(score).map(\.0) == [60, 67])
        #expect(score[Self.slot.withElementIndex(2)] == .rest(duration: .quarter))
    }

    /// A tenth is the widest MuseScore offers (`Alt+0`), so it is the widest this accepts.
    @Test("a tenth is accepted")
    func tenthIsAccepted() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try AddIntervalToSelection(over: Self.range, steps: 10).apply(to: &score)
        // C4 (60) plus the tenth above it, E5 (76) — the third, an octave up.
        #expect(Self.pitches(score).map(\.0) == [60, 76])
    }

    @Test("an interval outside 1…10, or a range that resolves to nothing, is refused")
    func refusals() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score
        let zero = #expect(throws: SheetMusicError.self) {
            _ = try AddIntervalToSelection(over: Self.range, steps: 0).apply(to: &score)
        }
        #expect(Self.reason(of: zero) == .invalidInterval(steps: 0))
        #expect(throws: SheetMusicError.self) {
            _ = try AddIntervalToSelection(over: Self.range, steps: 11).apply(to: &score)
        }
        let nowhere = VoiceElementRange(start: Self.slot, end: Self.slot.withElementIndex(9))
        #expect(throws: SheetMusicError.self) {
            _ = try AddIntervalToSelection(over: nowhere, steps: 3).apply(to: &score)
        }
        #expect(score == before)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
